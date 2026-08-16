import SwiftUI

struct AboutPane: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        Pane {
            HStack(alignment: .top, spacing: Space.roomy) {
                CaretMark(size: 44)
                    .foregroundStyle(Palette.accent)
                    .padding(.top, Space.hair)

                VStack(alignment: .leading, spacing: Space.tight) {
                    Text("Caret")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Palette.text)
                    Text("Version \(Self.version)")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.tertiaryText)
                    Text("Fixes words typed on the wrong keyboard layout, and stays quiet the rest of the time.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.snug)
                }
            }

            SettingsGroup("Status") {
                SettingRow(
                    "Accessibility access",
                    explanation: app.permissions.isTrusted
                        ? "Granted. Caret can watch and replace text."
                        : "Not granted. Caret cannot do anything until it is."
                ) {
                    if app.permissions.isTrusted {
                        Badge("On")
                    } else {
                        Button("Grant…") { app.permissions.openSettings() }
                            .controlSize(.small)
                    }
                }

                Hairline()

                SettingRow(
                    "Watching",
                    explanation: app.controller.isMonitoring
                        ? "Running."
                        : "Not running."
                ) {
                    Badge(app.controller.isMonitoring ? "On" : "Off")
                }
            }
        }
    }

    private static var version: String {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}

/// Caret's mark: a text insertion point, drawn rather than shipped as an image
/// so it stays crisp at any size and follows the accent colour.
struct CaretMark: View {
    var size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let width = canvasSize.width
            let height = canvasSize.height
            let stem = max(1.5, width * 0.09)
            let serif = width * 0.42
            let inset = height * 0.08

            var path = Path()
            // The vertical bar.
            path.addRoundedRect(
                in: CGRect(
                    x: (width - stem) / 2,
                    y: inset,
                    width: stem,
                    height: height - inset * 2
                ),
                cornerSize: CGSize(width: stem / 2, height: stem / 2)
            )
            // The serifs top and bottom, which is what makes it read as a caret
            // rather than a plain line.
            for y in [inset, height - inset - stem] {
                path.addRoundedRect(
                    in: CGRect(x: (width - serif) / 2, y: y, width: serif, height: stem),
                    cornerSize: CGSize(width: stem / 2, height: stem / 2)
                )
            }
            context.fill(path, with: .style(.foreground))
        }
        .frame(width: size * 0.62, height: size)
        .accessibilityHidden(true)
    }
}
