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
    @Published var screenshots: [ScreenshotItem] = []

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

    /// Domain → category name (e.g. "twitter.com" → "Social").
    @Published var categories: [String: String] = [:]

    private static let categoriesFile: URL =
        dataDirectory.appendingPathComponent("categories.json")

    init() {
        loadCategories()
        loadSelectedDay()
    }

    private func fileURL(for day: Date) -> URL {
        Store.dataDirectory.appendingPathComponent(DayKey.key(for: day) + ".json")
    }

    func loadSelectedDay() {
        entries = load(day: selectedDay).entries
        loadScreenshots()
    }

    func loadScreenshots() {
        let dayKey = DayKey.key(for: selectedDay)
        let dayDir = Store.screenshotsDirectory.appendingPathComponent(dayKey, isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dayDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else {
            screenshots = []
            return
        }

        screenshots = files
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .compactMap { url -> ScreenshotItem? in
                let name = url.deletingPathExtension().lastPathComponent
                let date = parseScreenshotTimestamp(name) ?? fileModDate(url) ?? Date()
                return ScreenshotItem(id: name, url: url, timestamp: date)
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Reverse the colon-to-dash substitution done by the Screenshotter.
    private func parseScreenshotTimestamp(_ name: String) -> Date? {
        guard let tIdx = name.firstIndex(of: "T") else { return nil }
        var chars = Array(name)
        let tPos = name.distance(from: name.startIndex, to: tIdx)
        // Positions tPos+3 and tPos+6 were colons before capture replaced them.
        if tPos + 6 < chars.count {
            chars[tPos + 3] = Character(":")
            chars[tPos + 6] = Character(":")
        }
        return ISO8601DateFormatter().date(from: String(chars))
    }

    private func fileModDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
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

    /// Removes a block written earlier today — used when a block turns out
    /// to be too short to count as real activity (see Tracker.minDuration).
    func discardToday(id: UUID) {
        let today = Date()
        var log = load(day: today)
        log.entries.removeAll { $0.id == id }
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

    /// Tasks for the selected day, with same-titled blocks combined into
    /// one row and the individual blocks kept as chunks underneath.
    var taskGroups: [TaskGroup] { groupTasks(entries) }

    /// Renames a whole task group by chunk ID (not by title — a
    /// time-clustered session's displayed title is auto-generated, not
    /// stored on any entry, so identity has to be the actual blocks).
    func renameGroup(ids: [UUID], newTitle: String, details: String) {
        var log = load(day: selectedDay)
        let idSet = Set(ids)
        var changed = false
        for i in log.entries.indices where idSet.contains(log.entries[i].id) {
            log.entries[i].title = newTitle
            log.entries[i].details = details
            // A manual rename is a deliberate, permanent label — treat it
            // like a rule match so this exact title keeps grouping by name
            // instead of drifting back into time-based session clustering.
            log.entries[i].ruleMatched = true
            changed = true
        }
        guard changed else { return }
        save(log, day: selectedDay)
        entries = log.entries
    }

    /// Deletes every block in a group by chunk ID.
    func deleteGroup(ids: [UUID]) {
        var log = load(day: selectedDay)
        let idSet = Set(ids)
        log.entries.removeAll { idSet.contains($0.id) }
        save(log, day: selectedDay)
        entries = log.entries
    }

    /// Total time per application (qualified by domain for browsers), longest first.
    var appTotals: [(app: String, total: TimeInterval)] {
        var totals: [String: TimeInterval] = [:]
        for e in entries { totals[e.displayAppName, default: 0] += e.duration }
        return totals.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    var dayTotal: TimeInterval { entries.reduce(0) { $0 + $1.duration } }

    // MARK: - Categories

    static let availableCategories = ["Work", "Social", "Communication", "Entertainment", "Learning"]

    func loadCategories() {
        guard let data = try? Data(contentsOf: Store.categoriesFile),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            categories = Store.defaultCategories
            saveCategories()
            return
        }
        categories = map
    }

    func saveCategories() {
        if let data = try? JSONSerialization.data(withJSONObject: categories,
                                                   options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Store.categoriesFile, options: .atomic)
        }
    }

    func setCategory(domain: String, category: String) {
        if category.isEmpty {
            categories.removeValue(forKey: domain)
        } else {
            categories[domain] = category
        }
        saveCategories()
    }

    func categoryFor(domain: String) -> String {
        guard !domain.isEmpty else { return "" }
        return categories[domain] ?? ""
    }

    /// Time per category for the selected day, longest first.
    var categoryTotals: [(category: String, total: TimeInterval)] {
        var totals: [String: TimeInterval] = [:]
        for e in entries {
            let cat = categoryFor(domain: e.domain)
            guard !cat.isEmpty else { continue }
            totals[cat, default: 0] += e.duration
        }
        return totals.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    private static let defaultCategories: [String: String] = [
        "twitter.com": "Social", "x.com": "Social",
        "facebook.com": "Social", "instagram.com": "Social",
        "reddit.com": "Social", "linkedin.com": "Social",
        "tiktok.com": "Social", "vk.com": "Social",
        "youtube.com": "Entertainment", "netflix.com": "Entertainment",
        "twitch.tv": "Entertainment", "spotify.com": "Entertainment",
        "github.com": "Work", "gitlab.com": "Work",
        "stackoverflow.com": "Work", "notion.so": "Work",
        "figma.com": "Work", "linear.app": "Work",
        "gmail.com": "Communication", "mail.google.com": "Communication",
        "slack.com": "Communication", "discord.com": "Communication",
        "telegram.org": "Communication", "web.telegram.org": "Communication",
        "docs.google.com": "Work", "drive.google.com": "Work",
        "sheets.google.com": "Work",
    ]

    // MARK: - Web API helpers (called from background threads)

    func entriesFor(dateKey: String) -> [TaskEntry] {
        guard let date = DayKey.formatter.date(from: dateKey) else { return [] }
        return load(day: date).entries
    }

    func updateEntryFor(dateKey: String, id: UUID, title: String, details: String) -> Bool {
        guard let date = DayKey.formatter.date(from: dateKey) else { return false }
        var log = load(day: date)
        guard let i = log.entries.firstIndex(where: { $0.id == id }) else { return false }
        log.entries[i].title = title
        log.entries[i].details = details
        save(log, day: date)
        if DayKey.key(for: selectedDay) == dateKey {
            DispatchQueue.main.async { self.entries = log.entries }
        }
        return true
    }

    func deleteEntryFor(dateKey: String, id: UUID) -> Bool {
        guard let date = DayKey.formatter.date(from: dateKey) else { return false }
        var log = load(day: date)
        guard log.entries.contains(where: { $0.id == id }) else { return false }
        log.entries.removeAll { $0.id == id }
        save(log, day: date)
        if DayKey.key(for: selectedDay) == dateKey {
            DispatchQueue.main.async { self.entries = log.entries }
        }
        return true
    }

    /// Renames a whole task group by chunk ID and sets their shared
    /// description. Marks the renamed blocks as rule-matched so this title
    /// keeps grouping them by name from now on (see groupTasks()).
    func renameGroupFor(dateKey: String, ids: [UUID], newTitle: String, details: String) -> Bool {
        guard let date = DayKey.formatter.date(from: dateKey) else { return false }
        var log = load(day: date)
        let idSet = Set(ids)
        var changed = false
        for i in log.entries.indices where idSet.contains(log.entries[i].id) {
            log.entries[i].title = newTitle
            log.entries[i].details = details
            log.entries[i].ruleMatched = true
            changed = true
        }
        guard changed else { return false }
        save(log, day: date)
        if DayKey.key(for: selectedDay) == dateKey {
            DispatchQueue.main.async { self.entries = log.entries }
        }
        return true
    }

    /// Deletes a whole task group by chunk ID.
    func deleteGroupFor(dateKey: String, ids: [UUID]) -> Bool {
        guard let date = DayKey.formatter.date(from: dateKey) else { return false }
        var log = load(day: date)
        let idSet = Set(ids)
        let before = log.entries.count
        log.entries.removeAll { idSet.contains($0.id) }
        guard log.entries.count != before else { return false }
        save(log, day: date)
        if DayKey.key(for: selectedDay) == dateKey {
            DispatchQueue.main.async { self.entries = log.entries }
        }
        return true
    }
}
