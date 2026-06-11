import Foundation
import Combine

/// Loads and saves day logs as JSON files in
/// ~/Library/Application Support/TaskTimeTracker/.
/// Everything stays on the local disk — this app contains no network code.
final class Store: ObservableObject {
    static let dataDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TaskTimeTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let screenshotsDirectory: URL = {
        let dir = dataDirectory.appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Day currently shown in the dashboard.
    @Published var selectedDay: Date = Date() {
        didSet { loadSelectedDay() }
    }
    @Published var entries: [TaskEntry] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        loadSelectedDay()
    }

    private func fileURL(for day: Date) -> URL {
        Store.dataDirectory.appendingPathComponent(DayKey.key(for: day) + ".json")
    }

    func loadSelectedDay() {
        entries = load(day: selectedDay).entries
    }

    private func load(day: Date) -> DayLog {
        guard let data = try? Data(contentsOf: fileURL(for: day)),
              let log = try? decoder.decode(DayLog.self, from: data) else {
            return DayLog()
        }
        return log
    }

    private func save(_ log: DayLog, day: Date) {
        if let data = try? encoder.encode(log) {
            try? data.write(to: fileURL(for: day), options: .atomic)
        }
    }

    // MARK: - Used by the tracker (always writes to "today")

    /// Insert a new entry or update the open one for today, then persist.
    func upsertToday(_ entry: TaskEntry) {
        let today = Date()
        var log = load(day: today)
        if let i = log.entries.firstIndex(where: { $0.id == entry.id }) {
            log.entries[i] = entry
        } else {
            log.entries.append(entry)
        }
        save(log, day: today)
        if DayKey.key(for: selectedDay) == DayKey.key(for: today) {
            entries = log.entries
        }
    }

    // MARK: - Used by the dashboard UI

    func updateEntry(_ entry: TaskEntry) {
        var log = load(day: selectedDay)
        if let i = log.entries.firstIndex(where: { $0.id == entry.id }) {
            log.entries[i] = entry
            save(log, day: selectedDay)
            entries = log.entries
        }
    }

    func deleteEntry(_ entry: TaskEntry) {
        var log = load(day: selectedDay)
        log.entries.removeAll { $0.id == entry.id }
        save(log, day: selectedDay)
        entries = log.entries
    }

    /// Total time per application for the selected day, longest first.
    var appTotals: [(app: String, total: TimeInterval)] {
        var totals: [String: TimeInterval] = [:]
        for e in entries { totals[e.appName, default: 0] += e.duration }
        return totals.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    var dayTotal: TimeInterval { entries.reduce(0) { $0 + $1.duration } }
}
