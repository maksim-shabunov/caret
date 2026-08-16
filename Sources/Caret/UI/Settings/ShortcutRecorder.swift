import AppKit
import CaretCore
import SwiftUI

/// Records a key combination the way every Mac app does: click, press the keys,
/// done.
///
/// It listens with a local event monitor rather than by becoming first
/// responder, which is what lets it capture combinations the app would otherwise
/// swallow as menu equivalents — ⌘Z among them, which is rather important here.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    /// Restored when the field is cleared, so there is always a way back.
    let fallback: Shortcut

    @State private var recorder = Recorder()
    @State private var isHovering = false

    var body: some View {
        Button {
            if recorder.isRecording {
                recorder.stop()
            } else {
                recorder.start { captured in
                    if let captured { shortcut = captured }
                }
            }
        } label: {
            Text(recorder.isRecording ? "Press keys…" : shortcut.displayString)
                .font(Typography.key)
                .foregroundStyle(recorder.isRecording ? Palette.accent : Palette.text)
                .frame(minWidth: 96)
                .padding(.horizontal, Space.normal)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .fill(recorder.isRecording ? Palette.accentWash : Palette.well)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .strokeBorder(
                            recorder.isRecording ? Palette.accent : Palette.hairline,
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Click, then press the keys you want. Escape cancels, Delete restores the default.")
        .accessibilityLabel("Shortcut")
        .accessibilityValue(shortcut.displayString)
        .onDisappear { recorder.stop() }
        .onChange(of: recorder.cleared) { _, cleared in
            if cleared { shortcut = fallback }
        }
    }
}

/// The event monitor behind the field.
@MainActor
@Observable
final class Recorder {

    private(set) var isRecording = false
    /// Flipped when the user presses Delete, asking for the default back.
    private(set) var cleared = false

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var completion: ((Shortcut?) -> Void)?

    func start(_ completion: @escaping (Shortcut?) -> Void) {
        stop()
        self.completion = completion
        isRecording = true
        cleared = false

        // Local monitors are delivered on the main thread as part of ordinary
        // event dispatch, which is what makes the main-actor hop unnecessary
        // here and the swallowed return value meaningful.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        completion = nil
    }

    /// Returns `nil` to swallow the event, which is what keeps the recorded
    /// keystroke from also doing whatever it normally does.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let keyCode = event.keyCode

        // Escape leaves things as they were.
        if keyCode == 53 {
            stop()
            return nil
        }

        // Delete asks for the default back.
        if keyCode == 51 {
            cleared = true
            stop()
            return nil
        }

        let modifiers = Shortcut.Modifiers(event.modifierFlags)

        // A shortcut with no modifier — or with only Shift — would fire in the
        // middle of ordinary typing. Keep listening instead of recording it.
        guard !modifiers.isEmpty, modifiers != [.shift] else { return nil }

        completion?(Shortcut(keyCode: keyCode, modifiers: modifiers))
        stop()
        return nil
    }
}

extension Shortcut.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var result: Shortcut.Modifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        self = result
    }
}
