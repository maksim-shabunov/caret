import CaretCore
import SwiftUI

/// What drops down from the menu bar.
///
/// Three things and no more: whether Caret is on, which layouts it is watching,
/// and what it has done lately. Anything that needs explaining lives in
/// Settings; this is meant to be read at a glance and dismissed.
struct MenuPanel: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.openSettings) private var openSettings

    private static let recentCount = 5

    var body: some View {
        @Bindable var preferences = app.preferences

        VStack(alignment: .leading, spacing: 0) {
            header(preferences: $preferences)

            if app.permissions.isTrusted {
                Hairline().padding(.vertical, Space.tight)
                layouts
                corrections
            } else {
                permissionNotice
            }

            Hairline().padding(.vertical, Space.tight)
            footer
        }
        .padding(Space.normal)
        .frame(width: 320)
        .background(Palette.canvas)
        .onAppear { app.synchronise() }
    }

    // MARK: - Header

    private func header(preferences: Bindable<Preferences>) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text("Caret")
                    .font(Typography.title)
                    .foregroundStyle(Palette.text)
                Text(app.statusSummary)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .contentTransition(.identity)
            }
            Spacer()
            Toggle("Correct layout mistakes", isOn: preferences.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Palette.accent)
                .onChange(of: preferences.wrappedValue.isEnabled) { app.synchronise() }
        }
        .padding(.horizontal, Space.snug)
        .padding(.vertical, Space.tight)
    }

    // MARK: - Layouts

    @ViewBuilder
    private var layouts: some View {
        let watched = app.controller.layouts.filter(app.preferences.isWatching)

        VStack(alignment: .leading, spacing: Space.snug) {
            SectionHeading("Layouts")

            if watched.count < 2 {
                // Nothing to convert between. Saying so is far kinder than
                // sitting there looking as though it works.
                Text("Caret needs at least two keyboard layouts to compare. Add one in System Settings › Keyboard.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.snug)
            } else {
                FlowRow(spacing: Space.snug) {
                    ForEach(watched) { layout in
                        Badge(layout.localizedName)
                    }
                }
                .padding(.horizontal, Space.snug)
            }
        }
        .padding(.vertical, Space.snug)
    }

    // MARK: - Recent corrections

    @ViewBuilder
    private var corrections: some View {
        let recent = Array(app.history.mostRecent.prefix(Self.recentCount))

        VStack(alignment: .leading, spacing: Space.snug) {
            SectionHeading("Recent")

            if recent.isEmpty {
                Text("Nothing yet. Caret stays quiet until it is sure.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.horizontal, Space.snug)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recent) { record in
                        CorrectionRow(record: record)
                    }
                }
            }
        }
        .padding(.vertical, Space.snug)
    }

    // MARK: - Permission

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: Space.normal) {
            Text("Caret needs permission to watch what you type and to put corrected text back. Nothing typed leaves your Mac.")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Setup") { app.showWelcome() }
                .buttonStyle(.accent)
        }
        .padding(.horizontal, Space.snug)
        .padding(.vertical, Space.normal)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                row("Settings…", shortcut: "⌘,")
            }
            .buttonStyle(.quiet)
            .keyboardShortcut(",", modifiers: .command)

            Button {
                NSApp.terminate(nil)
            } label: {
                row("Quit Caret", shortcut: "⌘Q")
            }
            .buttonStyle(.quiet)
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func row(_ title: String, shortcut: String) -> some View {
        HStack {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(Palette.text)
            Spacer()
            Text(shortcut)
                .font(Typography.caption)
                .foregroundStyle(Palette.tertiaryText)
        }
    }
}

/// Lays badges out left to right, wrapping when they run out of room.
///
/// Someone with five layouts installed should see all five rather than a row
/// that quietly truncates.
struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
