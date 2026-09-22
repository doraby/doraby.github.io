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
    /// True if `title` came from a rules.json match rather than the
    /// automatic "App — window" label. Rule-matched blocks are grouped by
    /// exact title (they were deliberately named); everything else is
    /// grouped by time proximity instead — see groupTasks().
    var ruleMatched: Bool = false
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

    // Custom decoder so existing JSON files without `url`/`ruleMatched` still load.
    enum CodingKeys: String, CodingKey {
        case id, appName, windowTitle, title, details, url, ruleMatched, start, end
    }

    init(appName: String, windowTitle: String, title: String,
         details: String = "", url: String = "", ruleMatched: Bool = false,
         start: Date, end: Date) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.title = title
        self.details = details
        self.url = url
        self.ruleMatched = ruleMatched
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
        ruleMatched = try c.decodeIfPresent(Bool.self, forKey: .ruleMatched) ?? false
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

/// A single task as shown in the dashboard: several of a day's tracked
/// blocks rolled into one row, with the individual blocks kept underneath
/// as expandable "chunks". This is what turns a dozen half-minute
/// Chrome/Terminal/Cursor blocks into one editable task instead of a dozen
/// tiny rows — see groupTasks() for how blocks are combined.
struct TaskGroup: Identifiable {
    var title: String
    /// Underlying blocks, sorted earliest first.
    var chunks: [TaskEntry]

    /// Identity is the chunk IDs, not the title — the title is just a
    /// (possibly auto-generated, possibly renamed) label, so two different
    /// groups can display the same text and a rename must not depend on it.
    var id: String { chunks.map { $0.id.uuidString }.joined() }
    var chunkIDs: [UUID] { chunks.map { $0.id } }
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

/// How far apart two blocks of the SAME app/site can be and still count as
/// one continuous task for automatic grouping.
private let sessionGap: TimeInterval = 600  // 10 minutes

/// Groups a day's flat entry list into TaskGroups, most recently active
/// group first.
///
/// Two different grouping strategies, combined:
/// - Blocks whose title came from a rules.json match are grouped by exact
///   title, anywhere in the day — you named that activity on purpose, so
///   e.g. every "Building Task Tracker" block (Cursor, Terminal, Chrome —
///   whatever matched the rule) becomes one task no matter when it happened.
/// - Everything else (plain auto-titled blocks — most of what you get with
///   no rules configured) is grouped by APP/SITE IDENTITY, chained across
///   time gaps up to `sessionGap`: every "Cursor" block becomes one task,
///   every "Chrome — nordstars.localhost" block becomes a separate task,
///   even if you were bouncing between them the whole time — a different
///   app or a different site is always a different task. Only *returning*
///   to the exact same app/site keeps extending its own task, so a dozen
///   quick Cursor visits interleaved with other apps still collapse into
///   one "Cursor" row instead of a dozen tiny ones, without also merging
///   in whatever else you touched in between.
func groupTasks(_ entries: [TaskEntry]) -> [TaskGroup] {
    let sorted = entries.sorted { $0.start < $1.start }

    var byRuleTitle: [String: [TaskEntry]] = [:]
    var byIdentity: [String: [TaskEntry]] = [:]
    for e in sorted {
        if e.ruleMatched {
            byRuleTitle[e.title, default: []].append(e)
        } else {
            byIdentity[identityKey(for: e), default: []].append(e)
        }
    }

    var groups = byRuleTitle.map { TaskGroup(title: $0.key, chunks: $0.value) }

    for (_, chunksForIdentity) in byIdentity {
        var session: [TaskEntry] = []
        func flushSession() {
            guard let first = session.first else { return }
            groups.append(TaskGroup(title: identityTitle(for: first), chunks: session))
            session = []
        }
        // Already sorted (came out of `sorted`, filtered in order).
        for e in chunksForIdentity {
            if let last = session.last, e.start.timeIntervalSince(last.end) > sessionGap {
                flushSession()
            }
            session.append(e)
        }
        flushSession()
    }

    return groups.sorted { $0.end > $1.end }
}

/// What counts as "the same activity" for grouping: the same app, and — if
/// it's a browser — the same site. Deliberately ignores the window/page
/// title beyond that, so e.g. different Cursor files still count as one
/// "Cursor" task; use a rule in rules.json when you want finer distinction.
private func identityKey(for e: TaskEntry) -> String {
    e.domain.isEmpty ? e.appName : "\(e.appName)|\(e.domain)"
}

private func identityTitle(for e: TaskEntry) -> String {
    e.domain.isEmpty ? e.appName : "\(e.appName) \u{2014} \(e.domain)"
}
