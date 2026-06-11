import Foundation

/// Optionally captures a periodic screenshot of the main display using the
/// system `screencapture` tool. Images are written only to the local
/// Screenshots folder; nothing leaves this machine.
final class Screenshotter {
    private var timer: Timer?
    /// Seconds between screenshots.
    private let interval: TimeInterval = 300

    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.capture()
        }
        timer?.tolerance = 10
        capture()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    private func capture() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dayDir = Store.screenshotsDirectory
            .appendingPathComponent(DayKey.key(for: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let file = dayDir.appendingPathComponent("\(stamp).jpg")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x: no sound, -t jpg: smaller files, -m: main display only
        proc.arguments = ["-x", "-m", "-t", "jpg", file.path]
        try? proc.run()
    }
}
