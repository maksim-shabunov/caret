import Foundation

/// One correction, as shown in the menu bar panel.
///
/// Deliberately thin: the two words, where it happened and when. Enough to
/// answer "what has this thing been doing?" and nothing more. Nothing typed
/// while secure input was active ever reaches this type.
public struct CorrectionRecord: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let original: String
    public let corrected: String
    public let layoutName: String
    public let applicationName: String
    public let date: Date
    public var reverted: Bool

    public init(
        id: UUID = UUID(),
        original: String,
        corrected: String,
        layoutName: String,
        applicationName: String,
        date: Date = Date(),
        reverted: Bool = false
    ) {
        self.id = id
        self.original = original
        self.corrected = corrected
        self.layoutName = layoutName
        self.applicationName = applicationName
        self.date = date
        self.reverted = reverted
    }
}
