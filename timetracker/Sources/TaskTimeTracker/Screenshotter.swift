import Foundation

/// Captures a screenshot 30 seconds after you switch to a new app/site —
/// timed so it shows what you've actually settled into, not the switch
/// itself — plus an occasional fallback shot if you stay in one app for a
/// long, uninterrupted stretch. Meant to be reviewed later (by you, or by
/// feeding them to an AI yourself) to work out what a task actually was;
/// this app does no image analysis itself. Uses the screencapture CLI with
/// -x (silent, no shutter sound, no audio permission prompt). Images are
/// written only to the local Screenshots folder — nothing leaves this Mac.
final class Screenshotter {
    /// Delay after an app switch before capturing.
    private let switchDelay: TimeInterval = 30
    /// If you stay in one app this long with no switch, capture anyway.
    private let fallbackInterval: TimeInterval = 600

    private var pendingSwitchCapture: DispatchWorkItem?
    private var fallbackTimer: Timer?
    private var lastCapture: Date?

    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fallbackTick()
        }
        fallbackTimer?.tolerance = 5
    }

    func stop() {
        isRunning = false
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        pendingSwitchCapture?.cancel()
        pendingSwitchCapture = nil
    }

    /// Call this whenever the Tracker starts a brand-new block (i.e. you
    /// switched to a different app/site). Debounced: flicking through
    /// several apps within the delay window only captures once, for
    /// whichever app you're actually in 30s later.
    func appDidSwitch() {
        guard isRunning else { return }
        pendingSwitchCapture?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.capture() }
        pendingSwitchCapture = item
        DispatchQueue.main.asyncAfter(deadline: .now() + switchDelay, execute: item)
    }

    private func fallbackTick() {
        guard isRunning else { return }
        if let last = lastCapture, Date().timeIntervalSince(last) < fallbackInterval { return }
        capture()
    }

    private func capture() {
        lastCapture = Date()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dayDir = Store.screenshotsDirectory
            .appendingPathComponent(DayKey.key(for: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let file = dayDir.appendingPathComponent("\(stamp).jpg")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-t", "jpg", file.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return }
        proc.waitUntilExit()
    }
}
