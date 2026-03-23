import Foundation
import XCTest

/// Regression test: new terminal must show the shell prompt without pressing Enter.
///
/// Requires: real Spindle on beast, SSH tunnel, fixture thread created by
/// Scripts/setup_xcui_fixture.swift (run via `task test:ui`).
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

        // Wait for thread row — try multiple query strategies since SwiftUI
        // List/NavigationSplitView renders different element types depending
        // on the accessibility tree.
        let threadQueries = [
            harness.app.outlines.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'thread.row.'")),
            harness.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'thread.row.'")),
            harness.app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'thread.row.'")),
            harness.app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'thread.row.'")),
        ]
        var threadRow: XCUIElement?
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            for query in threadQueries {
                let match = query.firstMatch
                if match.exists {
                    threadRow = match
                    break
                }
            }
            if threadRow != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard let threadRow else {
            let all = harness.app.descendants(matching: .any).allElementsBoundByIndex
            let identifiedElements = all.compactMap { elem -> String? in
                let id = elem.identifier
                guard !id.isEmpty else { return nil }
                return "\(elem.elementType.rawValue) [\(id)] '\(elem.label)'"
            }
            XCTFail("No thread row found.\nIdentified elements:\n\(identifiedElements.joined(separator: "\n"))")
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
        guard terminalView.waitForExistence(timeout: 20) else {
            let screenshot = harness.app.windows.firstMatch.screenshot()
            add(XCTAttachment(screenshot: screenshot))
            // Dump detail view elements
            let all = harness.app.descendants(matching: .any).allElementsBoundByIndex
            let ids = all.compactMap { e -> String? in
                let id = e.identifier
                guard !id.isEmpty, !id.hasPrefix("_XCUI") else { return nil }
                return "[\(id)] '\(e.label)'"
            }
            XCTFail("Terminal surface did not appear.\nElements:\n\(ids.joined(separator: "\n"))")
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

/// Launches Threadmill against real Spindle.
/// No GRDB seeding — the app syncs everything from Spindle on connect.
/// Fixture thread must be pre-created by Scripts/setup_xcui_fixture.swift.
@MainActor
struct RealSpindleUITestHarness {
    let app: XCUIApplication
    private let tempDirectory: URL

    static func launch() throws -> RealSpindleUITestHarness {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threadmill-uitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let databasePath = tempDirectory.appendingPathComponent("threadmill.db").path
        let appBundle = try locateAppBundle()

        let config = NSWorkspace.OpenConfiguration()
        var env = ProcessInfo.processInfo.environment
        env["THREADMILL_DISABLE_SSH_TUNNEL"] = "1"
        env["THREADMILL_HOST"] = "127.0.0.1"
        env["THREADMILL_DAEMON_PORT"] = "19990"
        // Use the default DB — the app already has the Remote configured.
        // THREADMILL_DB_PATH override creates an empty DB that breaks sync.
        config.environment = env
        config.activates = true

        var launchedApp: NSRunningApplication?
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: appBundle, configuration: config) { app, _ in
            launchedApp = app
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 15) == .success, launchedApp != nil else {
            throw UITestError("Failed to launch Threadmill")
        }

        let app = XCUIApplication(bundleIdentifier: "dev.threadmill.app")
        guard app.wait(for: .runningForeground, timeout: 15) else {
            throw UITestError("Threadmill did not reach foreground")
        }
        guard app.windows.firstMatch.waitForExistence(timeout: 15) else {
            app.terminate()
            throw UITestError("Threadmill window did not appear")
        }

        // Wait for Spindle connect + sync
        Thread.sleep(forTimeInterval: 5)

        return RealSpindleUITestHarness(app: app, tempDirectory: tempDirectory)
    }

    func tearDown() {
        app.terminate()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private static func locateAppBundle() throws -> URL {
        let root = repositoryRoot()
        for path in [".build/debug/Threadmill.app", ".build/arm64-apple-macosx/debug/Threadmill.app"] {
            let candidate = root.appendingPathComponent(path, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Contents/MacOS/Threadmill").path) {
                return candidate
            }
        }
        throw UITestError("Threadmill.app not found. Run: swift build --product Threadmill && bash Scripts/package_app.sh")
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
