import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let ruleEngine = RuleEngine()
    private lazy var tracker = Tracker(store: store, rules: ruleEngine)
    private let screenshotter = Screenshotter()
    private lazy var webServer = WebServer(store: store)
    private lazy var aiCron = AICron(store: store)

    private var statusItem: NSStatusItem!
    private var dashboardWindow: NSWindow?

    private let screenshotsKey = "screenshotsEnabled"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "clock.badge.checkmark",
            accessibilityDescription: "TaskTimeTracker"
        )
        statusItem.menu = buildMenu()

        tracker.onNewBlock = { [weak self] in self?.screenshotter.appDidSwitch() }
        tracker.start()
        webServer.start()
        if UserDefaults.standard.bool(forKey: screenshotsKey) {
            screenshotter.start()
        }
        // Completely inert until an API key is set — see AICron.swift.
        aiCron.start()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(withTitle: "Open in Browser", action: #selector(openBrowser), keyEquivalent: "d")
            .target = self
        menu.addItem(withTitle: "Open Dashboard (native)", action: #selector(openDashboard), keyEquivalent: "")
            .target = self

        let trackItem = NSMenuItem(title: "Pause Tracking", action: #selector(toggleTracking), keyEquivalent: "")
        trackItem.target = self
        menu.addItem(trackItem)

        let shotItem = NSMenuItem(title: "Enable Screenshots (30s after switching apps)",
                                  action: #selector(toggleScreenshots), keyEquivalent: "")
        shotItem.target = self
        shotItem.state = UserDefaults.standard.bool(forKey: screenshotsKey) ? .on : .off
        menu.addItem(shotItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Edit Task Rules…", action: #selector(editRules), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Reload Task Rules", action: #selector(reloadRules), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Set OpenAI API Key…", action: #selector(setAPIKey), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Run AI Task Analysis Now", action: #selector(runAINow), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Open Workflow Recommendations", action: #selector(openRecommendations), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Data Folder", action: #selector(openDataFolder), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
            .target = self
        return menu
    }

    @objc private func openBrowser() {
        if let url = URL(string: "http://localhost:\(webServer.actualPort)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openDashboard() {
        store.loadSelectedDay()
        if dashboardWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "Task Time Tracker"
            window.contentView = NSHostingView(rootView: DashboardView(store: store))
            window.isReleasedWhenClosed = false
            window.center()
            dashboardWindow = window
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleTracking(_ sender: NSMenuItem) {
        if tracker.isRunning {
            tracker.stop()
            sender.title = "Resume Tracking"
        } else {
            tracker.start()
            sender.title = "Pause Tracking"
        }
    }

    @objc private func toggleScreenshots(_ sender: NSMenuItem) {
        if screenshotter.isRunning {
            screenshotter.stop()
            sender.state = .off
            UserDefaults.standard.set(false, forKey: screenshotsKey)
        } else {
            screenshotter.start()
            sender.state = .on
            UserDefaults.standard.set(true, forKey: screenshotsKey)
        }
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.open(Store.dataDirectory)
    }

    @objc private func editRules() {
        NSWorkspace.shared.open(RuleEngine.rulesFileURL)
    }

    @objc private func reloadRules() {
        ruleEngine.reload()
    }

    @objc private func setAPIKey() {
        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Used only for the AI task-description / workflow-recommendation "
            + "features (menu below). Stored in your macOS Keychain, not in this repo or in plain "
            + "text. Enabling this means selected screenshots and task summaries are sent to "
            + "OpenAI's API — everything else in this app stays local. Leave blank and click "
            + "\"Clear\" to remove an existing key."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-…"
        field.stringValue = KeychainStore.getAPIKey() ?? ""
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { KeychainStore.setAPIKey(key) }
        case .alertSecondButtonReturn:
            KeychainStore.clearAPIKey()
        default:
            break
        }
    }

    @objc private func runAINow() {
        aiCron.runCycleIfPossible()
    }

    @objc private func openRecommendations() {
        if !FileManager.default.fileExists(atPath: AICron.recommendationsFile.path) {
            try? "No recommendations yet — they appear here after the AI analysis runs.\n"
                .write(to: AICron.recommendationsFile, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(AICron.recommendationsFile)
    }

    @objc private func quit() {
        tracker.stop()
        webServer.stop()
        aiCron.stop()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar-only app: no Dock icon.
app.setActivationPolicy(.accessory)
app.run()
