import AppKit
import Foundation

/// Polls the frontmost application every few seconds and turns contiguous
/// usage of one app into TaskEntry blocks, RescueTime-style.
final class Tracker {
    private let store: Store
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

    init(store: Store) {
        self.store = store
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

        if var entry = current, entry.appName == appName,
           now.timeIntervalSince(entry.end) < mergeGap {
            entry.end = now
            current = entry
            store.upsertToday(entry)
            return
        }

        closeCurrent()
        let title = frontWindowTitle(pid: app.processIdentifier)
        current = TaskEntry(
            appName: appName,
            windowTitle: title,
            title: TaskEntry.automaticTitle(appName: appName, windowTitle: title),
            start: now,
            end: now
        )
        store.upsertToday(current!)
    }

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
