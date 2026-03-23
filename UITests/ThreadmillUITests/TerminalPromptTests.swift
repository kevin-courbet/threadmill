import Foundation
import XCTest

/// Regression test: new terminal must show the shell prompt without pressing Enter.
///
/// This test launches the real app against real Spindle on beast (via SSH tunnel).
/// It creates a thread, opens a terminal, and waits for the ghostty surface to
/// render the prompt. If the prompt only appears after Enter, the test fails.
///
/// Unlike protocol-level tests, this exercises the full Mac rendering stack:
/// WebSocket → TerminalMultiplexer → RelayEndpoint → threadmill-relay → ghostty.
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

        // Thread was created before app launch (in RealSpindleUITestHarness.launch).
        // App synced on connect — thread should be in sidebar.
        let threadRow = harness.app.outlines.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'thread.row.'")
        ).firstMatch
        guard threadRow.waitForExistence(timeout: 30) else {
            // Take screenshot for debugging
            let screenshot = harness.app.windows.firstMatch.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "sidebar-no-thread"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("No thread row found in sidebar after creating test thread")
            return
        }
        threadRow.click()

        // Switch to Terminal mode
        try harness.clickMode(identifier: "mode.tab.terminal", label: "Terminal")

        // Wait for the terminal surface to appear
        let terminalView = harness.app.descendants(matching: .any)
            .matching(identifier: "terminal.surface")
            .firstMatch
        guard terminalView.waitForExistence(timeout: 15) else {
            XCTFail("Terminal surface did not appear")
            return
        }

        // Wait 5 seconds WITHOUT pressing any key. The prompt should render
        // from either capture_pane_visible replay or pipe-pane live output.
        Thread.sleep(forTimeInterval: 5)

        // Take a screenshot for debugging if the test fails
        let screenshot = harness.app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "terminal-before-enter"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Check the terminal's accessibility value for prompt content.
        // Ghostty surfaces expose their text content via accessibility.
        // We look for any prompt indicator in the terminal's text.
        let terminalText = terminalView.value as? String ?? ""
        let allText = harness.app.windows.firstMatch.debugDescription

        // The prompt must be visible. Check for common prompt characters.
        // Starship: "❯" or "via" or "at ". Basic shells: "$" or "%".
        let hasPrompt = terminalText.contains("❯")
            || terminalText.contains("$")
            || terminalText.contains("%")
            || terminalText.contains("via")
            || terminalText.contains("at ")
            || allText.contains("❯")
            || allText.contains("via")

        XCTAssertTrue(
            hasPrompt,
            "Terminal should show prompt without pressing Enter. Terminal value: \(terminalText.prefix(200))"
        )
    }
}

/// Launches the real Threadmill app against real Spindle on beast.
/// Requires SSH tunnel to be up (port 19990).
final class RealSpindleUITestHarness: @unchecked Sendable {
    let app: XCUIApplication
    private let tempDirectory: URL

    init(app: XCUIApplication, tempDirectory: URL) {
        self.app = app
        self.tempDirectory = tempDirectory
    }

    @MainActor
    static func launch() throws -> RealSpindleUITestHarness {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threadmill-uitest-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let homeDirectory = tempDirectory.appendingPathComponent("home", isDirectory: true)
        let preferencesDirectory = homeDirectory.appendingPathComponent("Library/Preferences", isDirectory: true)
        let configDirectory = homeDirectory.appendingPathComponent(".config", isDirectory: true)
        try FileManager.default.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        let databasePath = tempDirectory.appendingPathComponent("threadmill.db").path
        // Add fixture project and create thread BEFORE app launch —
        // the app syncs on connect and needs the project already in Spindle.
        let threadID = try createThreadBeforeLaunch()

        let appBundle = try locateAppBundle()
        let app = XCUIApplication(url: appBundle)
        app.launchEnvironment = [
            "THREADMILL_DISABLE_SSH_TUNNEL": "1",
            "THREADMILL_HOST": "127.0.0.1",
            "THREADMILL_DAEMON_PORT": "19990",
            "THREADMILL_DB_PATH": databasePath,
        ]
        app.launch()

        guard app.windows.firstMatch.waitForExistence(timeout: 15) else {
            app.terminate()
            throw UITestError("Threadmill window did not appear")
        }

        // Wait for connect + sync
        Thread.sleep(forTimeInterval: 3)

        let harness = RealSpindleUITestHarness(app: app, tempDirectory: tempDirectory)
        harness.createdThreadID = threadID
        return harness
    }

    private(set) var createdThreadID: String?

    func tearDown() {
        // Clean up test thread via Spindle RPC
        if let threadID = createdThreadID {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let conn = try? await SimpleSpindleClient.connect()
                _ = try? await conn?.rpc("thread.close", params: ["thread_id": threadID, "mode": "close"])
                conn?.disconnect()
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 10)
        }
        app.terminate()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// Creates fixture project + thread via Spindle RPC BEFORE app launch.
    private static func createThreadBeforeLaunch() throws -> String {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var error: Error?
        nonisolated(unsafe) var threadID: String?

        Task.detached { @Sendable in
            do {
                let conn = try await SimpleSpindleClient.connect()
                _ = try await conn.rpc("project.add", params: ["path": "/home/wsl/dev/threadmill-test-fixture"])
                let projects = try await conn.rpc("project.list", params: nil) as? [[String: Any]] ?? []
                guard let project = projects.first(where: { ($0["path"] as? String)?.contains("test-fixture") == true }),
                      let projectID = project["id"] as? String else {
                    error = UITestError("Fixture project not found")
                    sem.signal()
                    return
                }

                let name = "test-xcui-\(UUID().uuidString.prefix(8))"
                let result = try await conn.rpc("thread.create", params: [
                    "project_id": projectID, "name": name, "source_type": "new_feature"
                ], timeout: 30) as? [String: Any]
                threadID = result?["id"] as? String

                // Wait for thread to become active
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    if let event = try? await conn.waitForEvent("thread.status_changed", timeout: 5),
                       (event["thread_id"] as? String) == threadID,
                       (event["new"] as? String) == "active" {
                        break
                    }
                }

                conn.disconnect()
            } catch let e {
                error = e
            }
            sem.signal()
        }

        _ = sem.wait(timeout: .now() + 45)
        if let error { throw error }
        guard let id = threadID else { throw UITestError("Failed to create test thread") }
        return id
    }

    func waitForElement(identifier: String, timeout: TimeInterval = 15) throws -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard element.waitForExistence(timeout: timeout) else {
            throw UITestError("Element \(identifier) did not appear")
        }
        return element
    }

    func clickMode(identifier: String, label: String, timeout: TimeInterval = 15) throws {
        let byIdentifier = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if byIdentifier.waitForExistence(timeout: 2) {
            byIdentifier.click()
            return
        }
        let byLabel = app.segmentedControls.buttons[label].firstMatch
        guard byLabel.waitForExistence(timeout: timeout) else {
            throw UITestError("Mode \(identifier) / \(label) did not appear")
        }
        byLabel.click()
    }

    private static func locateAppBundle() throws -> URL {
        let root = repositoryRoot()
        let candidates = [
            root.appendingPathComponent(".build/debug/Threadmill.app", isDirectory: true),
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/Threadmill.app", isDirectory: true),
        ]
        for candidate in candidates where FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("Contents/MacOS/Threadmill").path
        ) {
            return candidate
        }
        throw UITestError("Threadmill.app not found. Run `bash Scripts/package_app.sh` first.")
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }


}
