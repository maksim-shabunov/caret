import AppKit
import SwiftUI

/// The first thing a new user sees, and the only place Caret ever asks for
/// anything.
///
/// It closes itself the moment permission is granted, so it never has to be
/// dismissed and never appears again unless the grant is taken away.
struct WelcomeWindow: View {
    let onDone: () -> Void

    @Environment(AppEnvironment.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Space.roomy) {
                CaretMark(size: 56)
                    .foregroundStyle(Palette.accent)

                VStack(spacing: Space.snug) {
                    Text("Caret")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Palette.text)
                    Text("Type a word on the wrong keyboard layout and Caret puts it right, before you have finished noticing.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 340)
                }
            }
            .padding(.top, Space.margin + Space.snug)
            .padding(.bottom, Space.section)

            VStack(spacing: 0) {
                point(
                    "eye",
                    "It watches only for gibberish",
                    "A word has to be nonsense where you typed it and sensible somewhere else. When in doubt, Caret does nothing."
                )
                Hairline()
                point(
                    "arrow.uturn.backward",
                    "Undo is always one key away",
                    "⌘Z for five seconds after a change, or \(app.preferences.revertShortcut.displayString) at any time."
                )
                Hairline()
                point(
                    "lock",
                    "Nothing leaves your Mac",
                    "Password fields are never read. Nothing is uploaded, ever."
                )
            }
            .cardBackground()
            .padding(.horizontal, Space.margin)

            footer
        }
        .frame(width: 460)
        .background(Palette.canvas)
        .onAppear { app.permissions.beginWatching() }
        .onChange(of: app.permissions.isTrusted) { _, trusted in
            guard trusted else { return }
            app.synchronise()
            // Nothing left to ask for. Long enough for the tick to register as
            // an answer rather than a flicker.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { onDone() }
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.normal) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Palette.accent)
                .frame(width: 20, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: Space.tight) {
                Text(title)
                    .font(Typography.control)
                    .foregroundStyle(Palette.text)
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.roomy)
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: Space.normal) {
            if app.permissions.isTrusted {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .font(Typography.body)
                    .foregroundStyle(Palette.accent)
                Button("Done") { onDone() }
                    .buttonStyle(.accent)
            } else {
                Text("Caret needs Accessibility access to see what you type and to put the corrected word back. It is the only permission it will ever ask for.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)

                // Only worth saying to someone who has been here before, which
                // is exactly who sees this window after an update: a downloaded
                // build is signed ad hoc — by its own contents — so every
                // version is a new signature, and the tick against the old one
                // grants nothing.
                if app.permissions.hasStaleGrant {
                    Text("Caret is already listed in Accessibility. Remove it with − and add it again — this version has a new signature, and the old entry no longer grants anything.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.tertiaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 380)
                }

                HStack(spacing: Space.normal) {
                    Button("Grant Access") { app.permissions.request() }
                        .buttonStyle(.accent)
                    Button("Open System Settings") { app.permissions.openSettings() }
                        .buttonStyle(.link)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
        }
        .padding(.top, Space.section)
        .padding(.bottom, Space.margin)
        .padding(.horizontal, Space.margin)
        .frame(maxWidth: .infinity)
    }
}
