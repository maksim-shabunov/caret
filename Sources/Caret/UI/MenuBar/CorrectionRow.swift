import CaretCore
import SwiftUI

/// One line in the recent-corrections list.
///
/// Reads as a sentence — what was typed, what it became, where and when — so
/// the list can be scanned without a header explaining the columns.
struct CorrectionRow: View {
    let record: CorrectionRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.snug) {
            HStack(spacing: Space.tight) {
                Text(record.original)
                    .foregroundStyle(Palette.tertiaryText)
                    .strikethrough(true, color: Palette.tertiaryText)

                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(record.reverted ? Palette.tertiaryText : Palette.accent)

                Text(record.corrected)
                    .foregroundStyle(record.reverted ? Palette.tertiaryText : Palette.text)
                    // A reverted correction is struck through on both sides:
                    // neither word is what is on screen now.
                    .strikethrough(record.reverted, color: Palette.tertiaryText)
            }
            .font(Typography.word)
            .lineLimit(1)
            .truncationMode(.middle)

            Spacer(minLength: Space.tight)

            Text(Self.time.string(from: record.date))
                .font(Typography.caption)
                .foregroundStyle(Palette.tertiaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, Space.snug)
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .help(record.applicationName.isEmpty ? "" : "in \(record.applicationName)")
    }

    private var accessibilityDescription: String {
        let action = record.reverted ? "Reverted" : "Corrected"
        let place = record.applicationName.isEmpty ? "" : " in \(record.applicationName)"
        return "\(action): \(record.original) to \(record.corrected)\(place)"
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
