import Carbon.HIToolbox
import Foundation

/// A keyboard layout reduced to what Caret needs: what each physical key
/// produces, plain and shifted, and the reverse lookup.
///
/// Built at runtime from the layout's own `uchr` data, so any layout the user
/// installs works without Caret knowing anything about it in advance.
public struct KeyboardLayout: Sendable, Identifiable, Equatable {
    public let id: String
    public let localizedName: String
    /// Language codes the layout declares, most specific first (e.g. `["ru"]`).
    public let languages: [String]

    /// keycode → character produced with no modifiers.
    public let plain: [UInt16: String]
    /// keycode → character produced with shift.
    public let shifted: [UInt16: String]
    /// character → the key that produces it. Covers both plain and shifted.
    public let reverse: [Character: (keyCode: UInt16, shift: Bool)]

    public var primaryLanguage: String { languages.first ?? "und" }

    public static func == (lhs: KeyboardLayout, rhs: KeyboardLayout) -> Bool {
        lhs.id == rhs.id
    }

    public init(
        id: String,
        localizedName: String,
        languages: [String],
        plain: [UInt16: String],
        shifted: [UInt16: String]
    ) {
        self.id = id
        self.localizedName = localizedName
        self.languages = languages
        self.plain = plain
        self.shifted = shifted

        // Build the reverse map. Plain wins over shifted where both produce the
        // same character, since typing it without shift is the simpler path.
        var reverse: [Character: (keyCode: UInt16, shift: Bool)] = [:]
        for (code, text) in shifted {
            guard let character = text.singleCharacter else { continue }
            reverse[character] = (code, true)
        }
        for (code, text) in plain {
            guard let character = text.singleCharacter else { continue }
            reverse[character] = (code, false)
        }
        self.reverse = reverse
    }

    /// What this layout produces for a given key press.
    public func character(for keyCode: UInt16, shift: Bool, capsLock: Bool = false) -> String? {
        guard let base = shift ? shifted[keyCode] : plain[keyCode] else { return nil }
        // Caps lock uppercases letters only; it leaves punctuation alone.
        if capsLock, !shift, base.isLowercasedLetter {
            return base.uppercased()
        }
        return base
    }
}

private extension String {
    var singleCharacter: Character? {
        count == 1 ? first : nil
    }

    var isLowercasedLetter: Bool {
        guard count == 1, let character = first else { return false }
        return character.isLetter && character.isLowercase
    }
}

/// Reads the currently installed keyboard layouts out of the Text Input Source
/// system and turns them into `KeyboardLayout` values.
///
/// Reading is confined to the main actor because it has to be: HIToolbox's
/// input-source calls abort the process outright when two threads enter them at
/// once. Caret's event tap runs on a thread of its own, so this is the sort of
/// crash that would only ever show up in front of the user — hence the
/// isolation, which turns it into a compiler error instead. Everything a
/// `KeyboardLayout` value holds is a plain copy, safe to read anywhere once it
/// has been built.
@MainActor
public enum KeyboardLayoutReader {
    /// Printable keys on a standard ANSI/ISO board. Modifier, function and
    /// keypad keys are deliberately absent — they never form part of a word.
    static let printableKeyCodes: [UInt16] = [
        // Number row
        18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24,
        // Top letter row
        12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30,
        // Home row
        0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39, 42,
        // Bottom row
        50, 6, 7, 8, 9, 11, 45, 46, 43, 47, 44,
        // ISO extra key present on European boards
        10,
    ]

    /// All enabled keyboard layouts, in the order the system reports them.
    public static func enabledLayouts() -> [KeyboardLayout] {
        let filter: [String: Any] = [
            kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String,
            kTISPropertyInputSourceIsEnabled as String: true,
        ]
        guard
            let sources = TISCreateInputSourceList(filter as CFDictionary, false)?
                .takeRetainedValue() as? [TISInputSource]
        else { return [] }

        return sources.compactMap(layout(from:))
    }

    /// The layout that is active right now.
    public static func currentLayout() -> KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }
        return layout(from: source)
    }

    static func layout(from source: TISInputSource) -> KeyboardLayout? {
        guard
            let id = stringProperty(source, kTISPropertyInputSourceID),
            let data = layoutData(source)
        else { return nil }

        let name = stringProperty(source, kTISPropertyLocalizedName) ?? id
        let languages = arrayProperty(source, kTISPropertyInputSourceLanguages) ?? []

        var plain: [UInt16: String] = [:]
        var shifted: [UInt16: String] = [:]
        let keyboardType = UInt32(LMGetKbdType())

        for code in printableKeyCodes {
            if let text = translate(data: data, keyCode: code, shift: false, keyboardType: keyboardType) {
                plain[code] = text
            }
            if let text = translate(data: data, keyCode: code, shift: true, keyboardType: keyboardType) {
                shifted[code] = text
            }
        }

        guard !plain.isEmpty else { return nil }

        return KeyboardLayout(
            id: id,
            localizedName: name,
            languages: languages,
            plain: plain,
            shifted: shifted
        )
    }

    /// Runs one key through `UCKeyTranslate`.
    ///
    /// Dead keys are resolved to nothing (`kUCKeyTranslateNoDeadKeysBit`), which
    /// makes them absent from the map. That is intentional: Caret never tries to
    /// reconstruct a dead-key sequence, it simply declines to correct one.
    static func translate(
        data: Data,
        keyCode: UInt16,
        shift: Bool,
        keyboardType: UInt32
    ) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        let modifiers: UInt32 = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0

        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(paramErr) }
            let keyboardLayout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(
                keyboardLayout,
                keyCode,
                UInt16(kUCKeyActionDown),
                modifiers,
                keyboardType,
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                buffer.count,
                &length,
                &buffer
            )
        }

        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: buffer, count: length)
        // Control characters are not text as far as Caret is concerned.
        guard !text.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        return text
    }

    static func layoutData(_ source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    static func stringProperty(_ source: TISInputSource, _ key: CFString!) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    static func arrayProperty(_ source: TISInputSource, _ key: CFString!) -> [String]? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
    }
}
