import Foundation

/// One user-defined classification rule. `pattern` is a regular expression
/// (case-insensitive) matched against "AppName — Window Title" for each
/// newly-started tracked block. The first matching rule wins.
struct TaskRule: Codable {
    var pattern: String
    /// Task title to use instead of the automatic "App — Window title".
    /// Leave out (or empty) to keep the automatic title but still tag a category.
    var title: String?
    /// Optional grouping label shown in the "Time per category" section.
    var category: String?
}

/// Loads rules.json from the data folder and classifies new tracked blocks
/// against it. Everything here is local pattern matching — no AI, no
/// network, no reading of screen pixels.
final class RuleEngine {
    static let rulesFileURL = Store.dataDirectory.appendingPathComponent("rules.json")

    private var compiled: [(regex: NSRegularExpression, rule: TaskRule)] = []

    init() {
        createDefaultFileIfNeeded()
        reload()
    }

    /// Re-reads rules.json from disk. Call after editing the file.
    func reload() {
        compiled = []
        guard let data = try? Data(contentsOf: Self.rulesFileURL),
              let rules = try? JSONDecoder().decode([TaskRule].self, from: data) else { return }
        for rule in rules {
            if let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) {
                compiled.append((regex, rule))
            }
        }
    }

    /// Returns the title/category to use for a new block, or nil if no rule
    /// matched (caller should fall back to the automatic title).
    func classify(appName: String, windowTitle: String) -> (title: String?, category: String?)? {
        let subject = "\(appName) — \(windowTitle)"
        let range = NSRange(subject.startIndex..., in: subject)
        for (regex, rule) in compiled {
            if regex.firstMatch(in: subject, options: [], range: range) != nil {
                return (rule.title?.isEmpty == false ? rule.title : nil, rule.category)
            }
        }
        return nil
    }

    private func createDefaultFileIfNeeded() {
        guard !FileManager.default.fileExists(atPath: Self.rulesFileURL.path) else { return }
        // Starter rules mirroring common examples — edit or replace freely.
        let starterRules: [TaskRule] = [
            TaskRule(pattern: "(Xcode|Visual Studio Code|Cursor).*(TaskTimeTracker|timetracker)",
                     title: "Building Task Tracker", category: "Coding"),
            TaskRule(pattern: "unschooler", title: "Testing Unschooler", category: "QA"),
            TaskRule(pattern: "Mail.*(Compose|New Message)",
                     title: "Writing customer email", category: "Communication"),
            TaskRule(pattern: "linkedin", title: "Editing LinkedIn post", category: "Marketing"),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(starterRules) {
            try? data.write(to: Self.rulesFileURL)
        }
    }
}
