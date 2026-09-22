import AppKit
import Foundation

/// Polls the frontmost application every few seconds and turns contiguous
/// usage of one app into TaskEntry blocks, RescueTime-style.
final class Tracker {
    private let store: Store
    private let rules: RuleEngine
    private var timer: Timer?
    private var current: TaskEntry?

    /// Poll interval in seconds.
    private let interval: TimeInterval = 5
    /// User input absent for longer than this stops the clock.
    private let idleLimit: TimeInterval = 180
    /// Returning to the same app within this gap extends the previous block
    /// instead of creating a new one.
    private let mergeGap: TimeInterval = 180

    private(set) var isRunning = false

    init(store: Store, rules: RuleEngine) {
        self.store = store
        self.rules = rules
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = 1
        tick()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        closeCurrent()
    }

    private func closeCurrent() {
        if let entry = current {
            store.upsertToday(entry)
            current = nil
        }
    }

    private func tick() {
        // Don't count time when the user is away from the keyboard.
        if systemIdleSeconds() > idleLimit {
            closeCurrent()
            return
        }

        guard let app = NSWorkspace.shared.frontmostApplication,
              let appName = app.localizedName else {
            closeCurrent()
            return
        }
        // Ignore time spent in this tracker's own dashboard.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            closeCurrent()
            return
        }

        let now = Date()

        // Close the open block at midnight so each entry belongs to one day.
        if let entry = current, DayKey.key(for: entry.start) != DayKey.key(for: now) {
            closeCurrent()
        }

        let url = activeTabURL(for: appName)
        let newDomain = domainFromURL(url)

        // Merge if same app AND same domain (so switching sites = new entry).
        if var entry = current, entry.appName == appName,
           entry.domain == newDomain,
           now.timeIntervalSince(entry.end) < mergeGap {
            entry.end = now
            if !url.isEmpty { entry.url = url }   // keep latest URL
            current = entry
            store.upsertToday(entry)
            return
        }

        closeCurrent()
        let autoTitle: String
        if !newDomain.isEmpty {
            autoTitle = "\(appName) \u{2014} \(newDomain)"
        } else {
            autoTitle = appName
        }
        current = TaskEntry(
            appName: appName,
            windowTitle: "",
            title: autoTitle,
            url: url,
            start: now,
            end: now
        )
        store.upsertToday(current!)
    }

    // MARK: - Browser URL capture

    /// Returns the active tab URL for supported browsers, or "" otherwise.
    /// Uses osascript subprocess which handles Automation permissions more reliably.
    private func activeTabURL(for appName: String) -> String {
        switch appName {
        case "Google Chrome":
            return runOsascript(
                "tell application \"Google Chrome\" to get URL of active tab of front window"
            )
        default:
            return ""
        }
    }

    private func runOsascript(_ source: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return "" }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func domainFromURL(_ raw: String) -> String {
        guard let c = URLComponents(string: raw), let host = c.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Seconds since the last keyboard/mouse event anywhere in the session.
    private func systemIdleSeconds() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .leftMouseDown, .rightMouseDown,
            .mouseMoved, .scrollWheel, .leftMouseDragged
        ]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }
}
