import SwiftUI

/// The real Settings window, opened by ⌘, like every other Mac app.
///
/// Five panes, each answering one question: is it on, what is it watching, what
/// are the keys, what does it remember, and what is it. Nothing is hidden behind
/// an "Advanced" disclosure — if a setting is worth having it is worth showing.
struct SettingsWindow: View {
    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            LayoutsPane()
                .tabItem { Label("Layouts", systemImage: "keyboard") }
            ShortcutsPane()
                .tabItem { Label("Shortcuts", systemImage: "command") }
            PrivacyPane()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
        .background(Palette.canvas)
    }
}

/// The shared frame every pane sits in, so switching tabs changes the content
/// and nothing else.
struct Pane<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                content
            }
            .padding(Space.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.canvas)
        .frame(minHeight: 260, maxHeight: 520)
    }
}

/// A titled group of rows in a card.
struct SettingsGroup<Content: View>: View {
    private let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            if let title {
                SectionHeading(title)
            }
            VStack(spacing: 0) {
                content
            }
            .cardBackground()
        }
    }
}
