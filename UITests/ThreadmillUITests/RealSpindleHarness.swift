import AppKit
import Foundation
import XCTest

/// Shared harness for XCUI tests against real Spindle on beast.
///
/// ## How it works
///
/// 1. Creates a temp directory with a fresh GRDB database
/// 2. Seeds the DB with a Remote pointing at real Spindle (127.0.0.1:19990
///    via SSH tunnel). Uses `DatabaseManager.ensureDefaultRemoteExists()` —
///    the same bootstrap path the app uses — then updates host/tunnel fields.
/// 3. Launches the pre-built Threadmill.app via `NSWorkspace.openApplication`
///    with `THREADMILL_DB_PATH` pointing at the temp DB. The app sees ONLY
///    fixture data — no interference from the user's real repos.
/// 4. The app connects to real Spindle, runs `project.list` + `thread.list`,
///    and syncs the fixture project + thread into the fresh DB.
/// 5. Tests interact with the app via XCUI.
///
/// ## Prerequisites (handled by `task test:ui`)
///
/// - SSH tunnel up: `ssh -N -f -L 127.0.0.1:19990:127.0.0.1:19990 beast`
/// - Spindle running on beast
/// - Fixture thread created: `swift Scripts/setup_xcui_fixture.swift`
/// - App built: `swift build --product Threadmill && bash Scripts/package_app.sh`
/// - Xcode project synced: `bash Scripts/sync_xcodeproj.sh`
///
/// ## Writing new XCUI tests
///
/// ```swift
/// @MainActor
/// final class MyFeatureTests: XCTestCase {
///     private var harness: RealSpindleHarness?
///
///     override func setUpWithError() throws {
///         try super.setUpWithError()
///         harness = try RealSpindleHarness.launch()
///     }
///
///     override func tearDownWithError() throws {
///         harness?.tearDown()
///         harness = nil
///         try super.tearDownWithError()
///     }
///
///     func testMyFeature() throws {
///         guard let harness else { throw XCTSkip("Harness not available") }
///         // harness.app is the XCUIApplication — query elements, click, type, assert
///         // The sidebar shows ONLY the fixture project + thread
///     }
/// }
/// ```
@MainActor
struct RealSpindleHarness {
    let app: XCUIApplication
    private let tempDirectory: URL

    static func launch() throws -> RealSpindleHarness {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threadmill-xcui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Seed GRDB with Remote through the app's own bootstrap path.
        // ensureDefaultRemoteExists() creates the "beast" remote, then we
        // update it to point at the tunneled Spindle on localhost.
        let databasePath = tempDirectory.appendingPathComponent("threadmill.db").path
        let database = try DatabaseManager(databasePath: databasePath)
        var remote = try database.ensureDefaultRemoteExists()
        remote.host = "127.0.0.1"
        remote.useSSHTunnel = false
        remote.daemonPort = 19990
        try database.saveRemote(remote)

        // Launch app with isolated DB — only fixture data visible
        let appBundle = try locateAppBundle()
        let config = NSWorkspace.OpenConfiguration()
        var env = ProcessInfo.processInfo.environment
        env["THREADMILL_DISABLE_SSH_TUNNEL"] = "1"
        env["THREADMILL_HOST"] = "127.0.0.1"
        env["THREADMILL_DAEMON_PORT"] = "19990"
        env["THREADMILL_DB_PATH"] = databasePath
        config.environment = env
        config.activates = true

        var launchedApp: NSRunningApplication?
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: appBundle, configuration: config) { app, _ in
            launchedApp = app
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 10) == .success, launchedApp != nil else {
            throw UITestError("Failed to launch Threadmill")
        }

        let app = XCUIApplication(bundleIdentifier: "dev.threadmill.app")
        guard app.wait(for: .runningForeground, timeout: 10) else {
            throw UITestError("Threadmill did not reach foreground")
        }
        guard app.windows.firstMatch.waitForExistence(timeout: 5) else {
            app.terminate()
            throw UITestError("Threadmill window did not appear")
        }

        // Wait for Spindle connect + sync
        Thread.sleep(forTimeInterval: 3)

        return RealSpindleHarness(app: app, tempDirectory: tempDirectory)
    }

    func tearDown() {
        app.terminate()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Helpers

    /// Wait for a fixture thread row in the sidebar (test-xcui-* threads)
    func waitForFixtureThread(timeout: TimeInterval = 10) -> XCUIElement? {
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'thread.row.' AND label CONTAINS 'test-xcui'")
        ).firstMatch
        return row.waitForExistence(timeout: timeout) ? row : nil
    }

    /// Click a mode tab by identifier (e.g., "mode.tab.terminal", "mode.tab.chat")
    func selectMode(_ modeID: String, timeout: TimeInterval = 5) throws {
        let tab = app.descendants(matching: .any).matching(identifier: modeID).firstMatch
        guard tab.waitForExistence(timeout: timeout) else {
            throw UITestError("Mode tab \(modeID) not found")
        }
        tab.click()
    }

    /// Take a screenshot and attach to the test case
    func screenshot(name: String, testCase: XCTestCase) {
        guard app.windows.firstMatch.exists else { return }
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    // MARK: - Private

    private static func locateAppBundle() throws -> URL {
        let root = repositoryRoot()
        for path in [".build/debug/Threadmill.app", ".build/arm64-apple-macosx/debug/Threadmill.app"] {
            let url = root.appendingPathComponent(path, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/Threadmill").path) {
                return url
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
