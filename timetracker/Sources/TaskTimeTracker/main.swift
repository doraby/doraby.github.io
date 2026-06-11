import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private lazy var tracker = Tracker(store: store)
    private let screenshotter = Screenshotter()

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

        tracker.start()
        if UserDefaults.standard.bool(forKey: screenshotsKey) {
            screenshotter.start()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(withTitle: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
            .target = self

        let trackItem = NSMenuItem(title: "Pause Tracking", action: #selector(toggleTracking), keyEquivalent: "")
        trackItem.target = self
        menu.addItem(trackItem)

        let shotItem = NSMenuItem(title: "Enable Screenshots (every 5 min)",
                                  action: #selector(toggleScreenshots), keyEquivalent: "")
        shotItem.target = self
        shotItem.state = UserDefaults.standard.bool(forKey: screenshotsKey) ? .on : .off
        menu.addItem(shotItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Data Folder", action: #selector(openDataFolder), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
            .target = self
        return menu
    }

    @objc private func openDashboard() {
        store.loadSelectedDay()
        if dashboardWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
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

    @objc private func quit() {
        tracker.stop()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar-only app: no Dock icon.
app.setActivationPolicy(.accessory)
app.run()
