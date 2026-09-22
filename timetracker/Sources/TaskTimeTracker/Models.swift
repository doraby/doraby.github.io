import Foundation

/// One tracked block of activity. Created automatically when an app becomes
/// frontmost; the user can later rename it and add a description.
struct TaskEntry: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    /// Name of the application that was in the foreground.
    var appName: String
    /// Window title captured when the block started (may be empty if
    /// Screen Recording permission was not granted).
    var windowTitle: String
    /// User-editable task title. Defaults to an automatic title.
    var title: String
    /// User-editable description.
    var details: String = ""
    /// Active browser tab URL (empty for non-browser apps).
    var url: String = ""
    var start: Date
    var end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Domain extracted from `url`, e.g. "github.com". Empty for non-browser entries.
    var domain: String {
        guard let c = URLComponents(string: url), let host = c.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// App name qualified with domain for browser entries.
    /// "Google Chrome — github.com" or just "Finder".
    var displayAppName: String {
        let d = domain
        return d.isEmpty ? appName : "\(appName) \u{2014} \(d)"
    }

    static func automaticTitle(appName: String, windowTitle: String) -> String {
        windowTitle.isEmpty ? appName : "\(appName) \u{2014} \(windowTitle)"
    }

    // Custom decoder so existing JSON files without `url` still load.
    enum CodingKeys: String, CodingKey {
        case id, appName, windowTitle, title, details, url, start, end
    }

    init(appName: String, windowTitle: String, title: String,
         details: String = "", url: String = "", start: Date, end: Date) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.title = title
        self.details = details
        self.url = url
        self.start = start
        self.end = end
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        appName = try c.decode(String.self, forKey: .appName)
        windowTitle = try c.decode(String.self, forKey: .windowTitle)
        title = try c.decode(String.self, forKey: .title)
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
    }
}

/// All data for one calendar day, persisted as a single JSON file.
struct DayLog: Codable {
    var entries: [TaskEntry] = []
}

enum DayKey {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func key(for date: Date) -> String { formatter.string(from: date) }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    let h = s / 3600, m = (s % 3600) / 60
    if h > 0 { return String(format: "%dh %02dm", h, m) }
    if m > 0 { return String(format: "%dm %02ds", m, s % 60) }
    return "\(s)s"
}

/// A screenshot captured by the Screenshotter, loaded from disk.
struct ScreenshotItem: Identifiable {
    let id: String      // filename, unique within a day
    let url: URL
    let timestamp: Date
}

/// A single task as shown in the dashboard: all of a day's tracked blocks
/// that share the same title (e.g. from a rule.json match, or simply the
/// same "App — window") rolled into one row, with the individual blocks
/// kept underneath as expandable "chunks". This is what turns five separate
/// half-minute Chrome/Terminal/Xcode blocks into one "Building Task
/// Tracker" task broken into chunks, instead of five tiny rows.
struct TaskGroup: Identifiable {
    var title: String
    /// Underlying blocks, sorted earliest first.
    var chunks: [TaskEntry]

    var id: String { title }
    var start: Date { chunks.first?.start ?? Date() }
    var end: Date { chunks.last?.end ?? Date() }
    var duration: TimeInterval { chunks.reduce(0) { $0 + $1.duration } }
    /// The single description shown/edited at the group level (kept in
    /// sync across all chunks when edited).
    var details: String { chunks.first?.details ?? "" }
    /// App that accounts for the most time in this group, for the accent color.
    var dominantApp: String {
        var totals: [String: TimeInterval] = [:]
        for c in chunks { totals[c.appName, default: 0] += c.duration }
        return totals.max { $0.value < $1.value }?.key ?? chunks.first?.appName ?? ""
    }
}

/// Groups a day's flat entry list into TaskGroups by exact title match,
/// most recently active group first.
func groupTasks(_ entries: [TaskEntry]) -> [TaskGroup] {
    var byTitle: [String: [TaskEntry]] = [:]
    for e in entries { byTitle[e.title, default: []].append(e) }
    return byTitle
        .map { TaskGroup(title: $0.key, chunks: $0.value.sorted { $0.start < $1.start }) }
        .sorted { $0.end > $1.end }
}
