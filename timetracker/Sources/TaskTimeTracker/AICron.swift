import Foundation

/// Runs on a timer (every 3 hours by default) and does two things, in
/// order, entirely optional and entirely inert until an OpenAI API key is
/// set (Keychain, see KeychainStore):
///
/// 1. For each task today that has a screenshot but hasn't been through
///    this before, sends ONE screenshot + the block's current title to a
///    cheap vision model and asks what the task actually is. The result
///    becomes the task's new title + gets appended to its description.
///    The app name itself is never touched by this — `appName` (and the
///    original `autoTitle`) stay on every block regardless of how many
///    times the display title gets rewritten.
/// 2. Once that pass is done, builds a full text log of today's tasks —
///    every block, every switch, down to the second — and asks the same
///    API for concrete workflow-improvement recommendations, which get
///    appended (with a timestamp) to a local recommendations file.
///
/// This is the only thing in the app that makes network calls, and only
/// screenshots/task titles picked for enrichment (not everything you do)
/// are sent, plus the once-per-cycle full-day text log for step 2.
final class AICron {
    private let store: Store
    private var timer: Timer?
    private(set) var isRunning = false
    private var isCycleInProgress = false

    /// How often the cycle runs.
    private let interval: TimeInterval = 3 * 60 * 60   // 3 hours
    /// Skip anything shorter than this — not worth a paid API call.
    private let minDurationForClassification: TimeInterval = 20
    /// Safety cap so a backlog can't trigger an unbounded number of calls.
    private let maxClassificationsPerCycle = 25

    static let recommendationsFile =
        Store.dataDirectory.appendingPathComponent("workflow-recommendations.txt")
    private static let logFile =
        Store.dataDirectory.appendingPathComponent("ai-log.txt")

    init(store: Store) {
        self.store = store
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.runCycleIfPossible()
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    /// Manual trigger (menu item), also just what the scheduled timer calls.
    func runCycleIfPossible() {
        guard !isCycleInProgress else { return }
        guard KeychainStore.getAPIKey()?.isEmpty == false else {
            log("Skipped: no OpenAI API key set (Menu bar -> Set OpenAI API Key…).")
            return
        }
        isCycleInProgress = true
        Task {
            await runCycle()
            await MainActor.run { self.isCycleInProgress = false }
        }
    }

    private func runCycle() async {
        let dateKey = DayKey.key(for: Date())
        await classifyPass(dateKey: dateKey)
        await recommendationsPass(dateKey: dateKey)
    }

    // MARK: - Pass 1: screenshot -> title/description

    private func classifyPass(dateKey: String) async {
        let shots = store.screenshotsFor(dateKey: dateKey)
        guard !shots.isEmpty else {
            log("Classify pass: no screenshots today, nothing to do.")
            return
        }

        let groups = groupTasks(store.entriesFor(dateKey: dateKey))
        let candidates = groups.filter {
            !$0.aiDescribed && $0.duration >= minDurationForClassification
                && !screenshotsForGroup($0, in: shots).isEmpty
        }
        guard !candidates.isEmpty else {
            log("Classify pass: nothing new to describe.")
            return
        }

        var done = 0
        for group in candidates.prefix(maxClassificationsPerCycle) {
            guard let shot = screenshotsForGroup(group, in: shots).first,
                  let imageData = try? Data(contentsOf: shot.url) else { continue }
            do {
                let result = try await OpenAIClient.classifyScreenshot(
                    currentTitle: group.title,
                    appName: group.dominantApp,
                    autoTitle: group.chunks.first?.autoTitle ?? group.title,
                    imageData: imageData
                )
                store.applyEnrichment(
                    dateKey: dateKey, ids: group.chunkIDs,
                    title: result.title, description: result.description
                )
                done += 1
            } catch {
                log("Classify FAILED for \"\(group.title)\": \(error)")
            }
        }
        log("Classify pass: described \(done)/\(candidates.count) task(s).")
    }

    // MARK: - Pass 2: full-day log -> workflow recommendations

    private func recommendationsPass(dateKey: String) async {
        let entries = store.entriesFor(dateKey: dateKey)
        guard !entries.isEmpty else { return }
        let logText = Self.dayLogText(entries: entries, dateKey: dateKey)
        do {
            let recommendations = try await OpenAIClient.workflowRecommendations(logText: logText)
            appendRecommendations(recommendations, dateKey: dateKey)
            log("Recommendations pass: wrote new recommendations.")
        } catch {
            log("Recommendations FAILED: \(error)")
        }
    }

    /// Every task, every underlying block, down to the second — this is
    /// exactly the granular log the recommendations prompt is built from.
    static func dayLogText(entries: [TaskEntry], dateKey: String) -> String {
        let tf = DateFormatter()
        tf.timeStyle = .medium
        let groups = groupTasks(entries).sorted { $0.start < $1.start }

        var lines: [String] = ["Date: \(dateKey)", ""]
        for g in groups {
            lines.append("TASK: \(g.title)  [\(formatDuration(g.duration))]  " +
                         "\(tf.string(from: g.start))\u{2013}\(tf.string(from: g.end))  " +
                         "(apps: \(g.appsUsed.joined(separator: ", ")))")
            if !g.details.isEmpty { lines.append("  description: \(g.details)") }
            for c in g.chunks {
                let site = c.domain.isEmpty ? c.windowTitle : c.domain
                let label = site.isEmpty ? c.appName : "\(c.appName) \u{2014} \(site)"
                lines.append("  - \(tf.string(from: c.start))\u{2013}\(tf.string(from: c.end)) " +
                             "(\(formatDuration(c.duration))) \(label)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func appendRecommendations(_ text: String, dateKey: String) {
        let header = "\n===== \(dateKey) \u{2014} \(ISO8601DateFormatter().string(from: Date())) =====\n"
        let entry = header + text + "\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.recommendationsFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.recommendationsFile)
        }
    }

    private func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.logFile)
        }
    }
}
