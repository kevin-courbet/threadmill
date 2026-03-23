import Foundation
import XCTest

/// Regression test: new terminal must show the shell prompt without pressing Enter.
///
/// Launches the real app against real Spindle on beast. Seeds GRDB with a
/// Remote so the app knows where to connect. On connect, the app syncs
/// projects and threads from Spindle — the fixture project appears in the
/// sidebar. The test then creates a thread via UI (New Thread sheet),
/// navigates to Terminal mode, and asserts the prompt renders.
@MainActor
final class TerminalPromptTests: XCTestCase {
    private var harness: RealSpindleUITestHarness?

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try RealSpindleUITestHarness.launch()
    }

    override func tearDownWithError() throws {
        harness?.tearDown()
        harness = nil
        try super.tearDownWithError()
    }

    func testNewTerminalShowsPromptWithoutEnterPress() throws {
        guard let harness else {
            throw XCTSkip("Harness not available")
        }

        // The fixture project should appear after sync. Look for it in sidebar.
        let projectElement = harness.app.outlines.staticTexts["threadmill-test-fixture"].firstMatch
        guard projectElement.waitForExistence(timeout: 15) else {
            let screenshot = harness.app.windows.firstMatch.screenshot()
            add(XCTAttachment(screenshot: screenshot))
            XCTFail("Fixture project did not appear in sidebar after sync")
            return
        }

        // Create a new thread via the UI
        // Click the + button next to the project
        let addButton = harness.app.buttons.matching(
            NSPredicate(format: "identifier == 'thread.new' OR label == 'New Thread'")
        ).firstMatch
        if addButton.waitForExistence(timeout: 5) {
            addButton.click()
        } else {
            // Try keyboard shortcut
            harness.app.typeKey("n", modifierFlags: [.command])
        }

        // Fill in thread name in the sheet
        let nameField = harness.app.textFields.firstMatch
        guard nameField.waitForExistence(timeout: 5) else {
            let screenshot = harness.app.windows.firstMatch.screenshot()
            add(XCTAttachment(screenshot: screenshot))
            XCTFail("New Thread sheet did not appear")
            return
        }
        nameField.click()
        nameField.typeText("test-xcui-prompt-\(UUID().uuidString.prefix(6))")

        // Submit the sheet (click Create or press Enter)
        let createButton = harness.app.buttons["Create"].firstMatch
        if createButton.waitForExistence(timeout: 3) {
            createButton.click()
        } else {
            nameField.typeKey(.return, modifierFlags: [])
        }

        // Wait for thread to appear and be selected
        let threadRow = harness.app.outlines.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'thread.row.'")
        ).firstMatch
        guard threadRow.waitForExistence(timeout: 30) else {
            let screenshot = harness.app.windows.firstMatch.screenshot()
            add(XCTAttachment(screenshot: screenshot))
            XCTFail("Thread row did not appear after creation")
            return
        }
        threadRow.click()

        // Switch to Terminal mode
        let terminalTab = harness.app.segmentedControls.buttons["Terminal"].firstMatch
        if terminalTab.waitForExistence(timeout: 5) {
            terminalTab.click()
        }

        // Wait for terminal surface
        let terminalView = harness.app.descendants(matching: .any)
            .matching(identifier: "terminal.surface")
            .firstMatch
        guard terminalView.waitForExistence(timeout: 15) else {
            let screenshot = harness.app.windows.firstMatch.screenshot()
            add(XCTAttachment(screenshot: screenshot))
            XCTFail("Terminal surface did not appear")
            return
        }

        // DO NOT press any key. Wait for prompt to arrive naturally.
        Thread.sleep(forTimeInterval: 5)

        let screenshot = harness.app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "terminal-before-enter"
        attachment.lifetime = .keepAlways
        add(attachment)

        let terminalText = terminalView.value as? String ?? ""
        let hasPrompt = terminalText.contains("❯")
            || terminalText.contains("$")
            || terminalText.contains("%")
            || terminalText.contains("via ")

        XCTAssertTrue(
            hasPrompt,
            "Terminal should show prompt without pressing Enter. Got: \(terminalText.prefix(300))"
        )
    }
}

// MARK: - Real Spindle UI Test Harness

/// Launches Threadmill against real Spindle on beast.
/// Seeds GRDB with a Remote pointing at localhost:19990 (SSH tunnel).
/// The app syncs projects/threads from Spindle on connect.
@MainActor
struct RealSpindleUITestHarness {
    let app: XCUIApplication

    private let tempDirectory: URL

    static func launch() throws -> RealSpindleUITestHarness {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threadmill-uitest-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let homeDirectory = tempDirectory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeDirectory.appendingPathComponent("Library/Preferences"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: homeDirectory.appendingPathComponent(".config"),
            withIntermediateDirectories: true
        )

        let databasePath = tempDirectory.appendingPathComponent("threadmill.db").path

        // DatabaseManager creates a default "beast" remote on init.
        // Update it to point at the real tunneled Spindle (127.0.0.1, no SSH tunnel).
        let database = try DatabaseManager(databasePath: databasePath)
        var remote = try database.ensureDefaultRemoteExists()
        remote.host = "127.0.0.1"
        remote.useSSHTunnel = false
        try database.saveRemote(remote)

        // Use NSWorkspace to launch the app — this registers it properly
        // with the window server so XCUIApplication can find it.
        let appBundle = try locateAppBundle()

        let config = NSWorkspace.OpenConfiguration()
        config.environment = [
            "THREADMILL_DISABLE_SSH_TUNNEL": "1",
            "THREADMILL_HOST": "127.0.0.1",
            "THREADMILL_DAEMON_PORT": "19990",
            "THREADMILL_DB_PATH": databasePath,
        ]
        config.activates = true

        var launchedApp: NSRunningApplication?
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: appBundle, configuration: config) { app, error in
            launchedApp = app
            if let error { NSLog("Launch error: %@", "\(error)") }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 15) == .success, launchedApp != nil else {
            throw UITestError("Failed to launch Threadmill via NSWorkspace")
        }

        let app = XCUIApplication(bundleIdentifier: "dev.threadmill.app")
        guard app.wait(for: .runningForeground, timeout: 15) else {
            throw UITestError("Threadmill did not reach foreground")
        }
        guard app.windows.firstMatch.waitForExistence(timeout: 15) else {
            app.terminate()
            throw UITestError("Threadmill window did not appear")
        }

        // Wait for connect + project sync
        Thread.sleep(forTimeInterval: 3)

        return RealSpindleUITestHarness(app: app, tempDirectory: tempDirectory)
    }

    func tearDown() {
        app.terminate()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private static func locateAppBundle() throws -> URL {
        let root = repositoryRoot()
        for path in [
            ".build/debug/Threadmill.app",
            ".build/arm64-apple-macosx/debug/Threadmill.app",
        ] {
            let candidate = root.appendingPathComponent(path, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Contents/MacOS/Threadmill").path) {
                return candidate
            }
        }
        throw UITestError("Threadmill.app not found. Run `swift build --product Threadmill && bash Scripts/package_app.sh`.")
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
