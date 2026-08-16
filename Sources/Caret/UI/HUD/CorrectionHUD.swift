import AppKit
import CaretCore
import SwiftUI

/// The brief note that appears when a correction lands.
///
/// It exists for one reason: a correction the user did not notice is a
/// correction they cannot undo. So it shows what changed and how to reverse it,
/// then leaves. It never takes focus, never accepts a click, and never asks for
/// anything — the text is already fixed by the time it appears.
///
/// A panel rather than a window, non-activating and mouse-transparent, so it
/// cannot interrupt typing even in principle.
@MainActor
final class CorrectionHUD {

    private static let fadeIn: TimeInterval = 0.12
    private static let hold: TimeInterval = 2.0
    private static let fadeOut: TimeInterval = 0.28

    /// How far above the bottom of the screen the note floats. Clear of the
    /// Dock, well away from where anyone is actually typing.
    private static let bottomInset: CGFloat = 120

    private var panel: NSPanel?
    private var dismissal: Timer?

    func show(_ proposal: CorrectionProposal) {
        let panel = panel ?? makePanel()
        self.panel = panel

        let view = HUDContent(proposal: proposal)
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        panel.contentView = hosting

        let size = hosting.fittingSize
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrame(
            NSRect(
                x: frame.midX - size.width / 2,
                y: frame.minY + Self.bottomInset,
                width: size.width,
                height: size.height
            ),
            display: false
        )

        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: the note
        // must never pull focus out of whatever the user is typing into.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        dismissal?.invalidate()
        dismissal = Timer.scheduledTimer(withTimeInterval: Self.hold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss() {
        dismissal?.invalidate()
        dismissal = nil
        guard let panel else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Follow the user everywhere, including into full screen, and do not
        // count as a window for anything.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        return panel
    }
}

/// What the note actually says: the old word, the new word, and the way back.
private struct HUDContent: View {
    let proposal: CorrectionProposal

    var body: some View {
        HStack(spacing: Space.snug) {
            Text(proposal.original)
                .foregroundStyle(Palette.tertiaryText)
                .strikethrough(true, color: Palette.tertiaryText)

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Palette.accent)

            Text(proposal.corrected)
                .foregroundStyle(Palette.text)

            Text("⌘Z")
                .font(Typography.caption)
                .foregroundStyle(Palette.tertiaryText)
                .padding(.leading, Space.tight)
        }
        .font(Typography.word)
        .padding(.horizontal, Space.roomy)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Palette.shadow, radius: 10, x: 0, y: 3)
        )
        .padding(Space.normal)
        .fixedSize()
    }
}
