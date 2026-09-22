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
    /// Returning to the same app+site within this gap extends the previous
    /// block instead of creating a new one.
    private let mergeGap: TimeInterval = 180
    /// Blocks shorter than this are discarded as noise (a momentary
    /// window/tab focus flicker, not real activity) instead of being saved.
    private let minDuration: TimeInterval = 3

    private(set) var isRunning = false

    /// Called whenever a brand-new block starts (i.e. you switched to a
    /// different app/site) — NOT on every tick, and not when an existing
    /// block just gets extended. Used to trigger a screenshot 30s later.
    var onNewBlock: (() -> Void)?

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
        guard let entry = current else { return }
        current = nil
        if entry.duration < minDuration {
            // Too short to be real activity (a momentary flicker between
            // windows) — discard rather than leave a near-zero-length row.
            store.discardToday(id: entry.id)
        } else {
            store.upsertToday(entry)
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

        // Real window title (file name in an editor, subject in Mail, etc).
        // For a browser this is usually just the active tab's page title.
        let windowTitle = frontWindowTitle(pid: app.processIdentifier)
        let url = activeTabURL(for: appName)
        let newDomain = domainFromURL(url)

        // Merge if same app AND same site (so switching sites = new entry).
        if var entry = current, entry.appName == appName,
           entry.domain == newDomain,
           now.timeIntervalSince(entry.end) < mergeGap {
            entry.end = now
            if !url.isEmpty { entry.url = url }
            if !windowTitle.isEmpty { entry.windowTitle = windowTitle }
            current = entry
            store.upsertToday(entry)
            return
        }

        closeCurrent()

        // A rule (rules.json) can turn "Xcode — Tracker.swift" or
        // "Google Chrome — Building a budget spreadsheet" into a specific,
        // human task title. No AI, no screenshots — just text matching on
        // what macOS already reports as the window/tab title.
        let matched = rules.classify(appName: appName, windowTitle: windowTitle)
        let fallbackTitle: String
        if !windowTitle.isEmpty {
            fallbackTitle = TaskEntry.automaticTitle(appName: appName, windowTitle: windowTitle)
        } else if !newDomain.isEmpty {
            fallbackTitle = "\(appName) \u{2014} \(newDomain)"
        } else {
            fallbackTitle = appName
        }
        let resolvedTitle = matched?.title ?? fallbackTitle

        current = TaskEntry(
            appName: appName,
            windowTitle: windowTitle,
            title: resolvedTitle,
            url: url,
            ruleMatched: matched?.title != nil,
            autoTitle: fallbackTitle,
            start: now,
            end: now
        )
        store.upsertToday(current!)
        onNewBlock?()
    }

    // MARK: - Window title (all apps)

    /// Title of the frontmost window of the given process. Returns "" unless
    /// the app has been granted Screen Recording permission (macOS requires
    /// it to read other apps' window titles).
    private func frontWindowTitle(pid: pid_t) -> String {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return "" }

        for window in info {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }
            return (window[kCGWindowName as String] as? String) ?? ""
        }
        return ""
    }

    // MARK: - Browser URL capture (for same-site merging + category rules)

    /// Returns the active tab URL for supported browsers, or "" otherwise.
    /// Uses an osascript subprocess, which handles Automation permission
    /// prompts more reliably than the JS/Apple Events APIs directly.
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
