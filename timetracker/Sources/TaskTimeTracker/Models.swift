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
    var start: Date
    var end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }

    static func automaticTitle(appName: String, windowTitle: String) -> String {
        windowTitle.isEmpty ? appName : "\(appName) — \(windowTitle)"
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
