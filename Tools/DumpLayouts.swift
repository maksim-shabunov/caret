import Foundation
@preconcurrency import Carbon.HIToolbox

// Snapshot the layouts the tests are written against, so the suite stops
// depending on which input sources this particular Mac happens to have enabled.
let wanted = [
    "com.apple.keylayout.ABC",
    "com.apple.keylayout.Russian",
    "com.apple.keylayout.Estonian",
]

let printableKeyCodes: [UInt16] = [
    18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24,
    12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30,
    0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39, 42,
    50, 6, 7, 8, 9, 11, 45, 46, 43, 47, 44,
    10,
]

func translate(data: Data, keyCode: UInt16, shift: Bool, keyboardType: UInt32) -> String? {
    var deadKeyState: UInt32 = 0
    var length = 0
    var buffer = [UniChar](repeating: 0, count: 8)
    let modifiers: UInt32 = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
    let status = data.withUnsafeBytes { raw -> OSStatus in
        guard let base = raw.baseAddress else { return OSStatus(paramErr) }
        return UCKeyTranslate(
            base.assumingMemoryBound(to: UCKeyboardLayout.self), keyCode,
            UInt16(kUCKeyActionDown), modifiers, keyboardType,
            UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
            buffer.count, &length, &buffer)
    }
    guard status == noErr, length > 0 else { return nil }
    let text = String(utf16CodeUnits: buffer, count: length)
    guard !text.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
    return text
}

let filter: [String: Any] = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String]
let sources = TISCreateInputSourceList(filter as CFDictionary, true)!
    .takeRetainedValue() as! [TISInputSource]

var output: [[String: Any]] = []
for source in sources {
    guard
        let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
        case let id = Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String,
        wanted.contains(id),
        let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { continue }

    let data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue() as Data
    let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName).map {
        Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
    } ?? id
    let languages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages).map {
        Unmanaged<CFArray>.fromOpaque($0).takeUnretainedValue() as! [String]
    } ?? []

    var plain: [String: String] = [:]
    var shifted: [String: String] = [:]
    let keyboardType = UInt32(LMGetKbdType())
    for code in printableKeyCodes {
        if let t = translate(data: data, keyCode: code, shift: false, keyboardType: keyboardType) { plain["\(code)"] = t }
        if let t = translate(data: data, keyCode: code, shift: true, keyboardType: keyboardType) { shifted["\(code)"] = t }
    }
    output.append([
        "id": id, "localizedName": name, "languages": languages,
        "plain": plain, "shifted": shifted,
    ])
    print("dumped \(id) — \(plain.count) plain, \(shifted.count) shifted, langs \(languages.prefix(3))")
}

output.sort { ($0["id"] as! String) < ($1["id"] as! String) }
let json = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: "Tests/CaretCoreTests/Layouts.json"))
print("wrote Tests/CaretCoreTests/Layouts.json (\(json.count) bytes)")
