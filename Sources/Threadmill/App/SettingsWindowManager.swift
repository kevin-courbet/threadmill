import AppKit
import SwiftUI

@MainActor
final class SettingsWindowManager: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowManager()

    private var settingsWindow: NSWindow?

    private override init() {
        super.init()
    }

    func show(
        appState: AppState,
        databaseManager: (any DatabaseManaging)?,
        gitHubAuthManager: GitHubAuthManager
    ) {
        if let existingWindow = settingsWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(
            databaseManager: databaseManager,
            gitHubAuthManager: gitHubAuthManager
        )
        .environment(appState)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 700, height: 500))
        window.minSize = NSSize(width: 650, height: 400)
        window.delegate = self

        window.center()
        window.makeKeyAndOrderFront(nil)

        settingsWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow == settingsWindow else {
            return
        }
        settingsWindow = nil
    }
}
