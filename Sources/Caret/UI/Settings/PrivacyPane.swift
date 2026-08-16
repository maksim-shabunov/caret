import AppKit
import CaretCore
import SwiftUI
import UniformTypeIdentifiers

/// What Caret keeps, and where it refuses to look.
struct PrivacyPane: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        @Bindable var preferences = app.preferences

        Pane {
            VStack(alignment: .leading, spacing: Space.snug) {
                SectionHeading("On this Mac")
                Text("Everything Caret does happens on your Mac. Nothing you type is sent anywhere, and text typed into a password field is never looked at, buffered or recorded at all.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Space.tight)
            }

            SettingsGroup {
                SettingRow(
                    "Remember recent corrections",
                    explanation: "Keeps the last \(HistoryStore.limit) between launches. Turn this off and the list lives only as long as the app does."
                ) {
                    Toggle("", isOn: $preferences.keepHistoryOnDisk)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Palette.accent)
                        .onChange(of: preferences.keepHistoryOnDisk) {
                            app.history.setPersists(preferences.keepHistoryOnDisk)
                        }
                }

                Hairline()

                SettingRow(
                    "Recent corrections",
                    explanation: app.history.records.isEmpty
                        ? "Nothing recorded."
                        : "\(app.history.records.count) recorded."
                ) {
                    Button("Clear") { app.history.clear() }
                        .disabled(app.history.records.isEmpty)
                }
            }

            excludedApps
        }
    }

    // MARK: - Excluded apps

    private var excludedApps: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading("Never in these apps")
                Spacer()
                Button("Add…") { addApplication() }
                    .controlSize(.small)
            }

            Text("Caret stops watching entirely while one of these is in front — no correcting, no shortcuts, nothing buffered.")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Space.tight)

            SettingsGroup {
                let excluded = app.preferences.excludedBundleIDs.sorted { name(for: $0) < name(for: $1) }
                if excluded.isEmpty {
                    Text("No apps excluded.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                        .padding(Space.roomy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(excluded.enumerated()), id: \.element) { index, bundleID in
                        if index > 0 { Hairline() }
                        SettingRow(name(for: bundleID), explanation: bundleID) {
                            Button("Remove") {
                                app.preferences.excludedBundleIDs.remove(bundleID)
                                app.controller.preferencesChanged()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        panel.message = "Choose apps Caret should leave alone."

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            app.preferences.excludedBundleIDs.insert(id)
        }
        app.controller.preferencesChanged()
    }

    /// The app's own name where macOS still knows it, the identifier where it
    /// does not — an app can be uninstalled while its exclusion remains.
    private func name(for bundleID: String) -> String {
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let name = Bundle(url: url)?.localizedName
        else { return bundleID }
        return name
    }
}

private extension Bundle {
    var localizedName: String? {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundleURL.deletingPathExtension().lastPathComponent
    }
}
