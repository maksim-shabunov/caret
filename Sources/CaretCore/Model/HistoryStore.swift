import Foundation
import Observation

/// The recent-corrections list behind the menu bar panel.
@MainActor
@Observable
public final class HistoryStore {

    public static let limit = 50

    public private(set) var records: [CorrectionRecord] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var persists: Bool

    public init(persists: Bool, directory: URL? = nil) {
        self.persists = persists
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Caret", isDirectory: true)
        fileURL = base.appendingPathComponent("history.json")

        if persists { load() }
    }

    /// Newest first, which is the order the panel shows them in.
    public var mostRecent: [CorrectionRecord] {
        records.reversed()
    }

    public func add(_ record: CorrectionRecord) {
        records.append(record)
        if records.count > Self.limit {
            records.removeFirst(records.count - Self.limit)
        }
        save()
    }

    public func markReverted(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].reverted = true
        save()
    }

    public func clear() {
        records.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Turning persistence off also removes what is already on disk — otherwise
    /// the setting would be a lie until the next correction.
    public func setPersists(_ newValue: Bool) {
        guard persists != newValue else { return }
        persists = newValue
        if newValue {
            save()
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Disk

    private func load() {
        guard
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([CorrectionRecord].self, from: data)
        else { return }
        records = decoded.suffix(Self.limit)
    }

    private func save() {
        guard persists else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // History is a convenience. Losing it must never disturb typing.
        }
    }
}
