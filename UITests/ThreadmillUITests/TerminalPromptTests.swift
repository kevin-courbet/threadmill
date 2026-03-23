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

    override func setUp() async throws {
        try await super.setUp()
        harness = try RealSpindleUITestHarness.launch()
    }

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    func testNewTerminalShowsPromptWithoutEnterPress() throws {
        guard let harness else {
            throw XCTSkip("Harness not available")
        }

        // Select the thread in the sidebar
        _ = try harness.waitForElement(identifier: "thread.row", timeout: 15)
        let threadRow = harness.app.outlines.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'thread.row.'")
        ).firstMatch
        guard threadRow.waitForExistence(timeout: 10) else {
            XCTFail("No thread row found in sidebar")
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
@MainActor
struct RealSpindleUITestHarness {
    let app: XCUIApplication
    private let appProcess: Process
    private let tempDirectory: URL

    static func launch() throws -> RealSpindleUITestHarness {
        // Verify tunnel is up
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        checkProcess.arguments = ["-z", "127.0.0.1", "19990"]
        checkProcess.standardOutput = FileHandle.nullDevice
        checkProcess.standardError = FileHandle.nullDevice
        try checkProcess.run()
        checkProcess.waitUntilExit()
        guard checkProcess.terminationStatus == 0 else {
            throw UITestError("SSH tunnel not up on port 19990. Run: ssh -N -f -L 127.0.0.1:19990:127.0.0.1:19990 beast")
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threadmill-uitest-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let homeDirectory = tempDirectory.appendingPathComponent("home", isDirectory: true)
        let preferencesDirectory = homeDirectory.appendingPathComponent("Library/Preferences", isDirectory: true)
        let configDirectory = homeDirectory.appendingPathComponent(".config", isDirectory: true)
        try FileManager.default.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        let databasePath = tempDirectory.appendingPathComponent("threadmill.db").path

        let appBundle = try locateAppBundle()
        let process = Process()
        process.executableURL = appBundle.appendingPathComponent("Contents/MacOS/Threadmill")
        process.currentDirectoryURL = repositoryRoot()

        var environment = ProcessInfo.processInfo.environment
        environment["THREADMILL_DISABLE_SSH_TUNNEL"] = "1"
        environment["THREADMILL_HOST"] = "127.0.0.1"
        environment["THREADMILL_DAEMON_PORT"] = "19990"
        environment["THREADMILL_DB_PATH"] = databasePath
        // Do NOT set THREADMILL_USE_MOCK_TERMINAL — we need real ghostty rendering
        environment["HOME"] = homeDirectory.path
        environment["CFFIXED_USER_HOME"] = homeDirectory.path
        environment["XDG_CONFIG_HOME"] = configDirectory.path
        process.environment = environment

        try process.run()
        try waitForLaunchedApplication(processIdentifier: process.processIdentifier)

        let app = XCUIApplication(bundleIdentifier: "dev.threadmill.app")
        NSRunningApplication(processIdentifier: process.processIdentifier)?
            .activate(options: [.activateIgnoringOtherApps])

        guard app.windows.firstMatch.waitForExistence(timeout: 15) else {
            process.terminate()
            throw UITestError("Threadmill window did not appear")
        }

        // Wait for the app to connect and sync
        Thread.sleep(forTimeInterval: 3)

        return RealSpindleUITestHarness(app: app, appProcess: process, tempDirectory: tempDirectory)
    }

    func tearDown() {
        if appProcess.isRunning {
            appProcess.terminate()
            appProcess.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: tempDirectory)
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

    private static func waitForLaunchedApplication(processIdentifier: Int32) throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if NSRunningApplication(processIdentifier: processIdentifier) != nil {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw UITestError("Threadmill process did not register with Launch Services")
    }
}
