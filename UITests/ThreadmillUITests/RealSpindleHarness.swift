import AppKit
import Foundation
import XCTest

/// Harness for XCUI e2e tests. Launches the real app against real Spindle on beast.
///
/// Prerequisites (handled by `task test:ui`):
/// - SSH tunnel on :19990
/// - Spindle running on beast
/// - Fixture thread created via `Scripts/setup_xcui_fixture.swift`
/// - App built and packaged
///
/// Diagnostics: on failure, filter Console.app with `subsystem:dev.threadmill`
/// to see structured os.Logger output from the app process.
@MainActor
struct TestHarness {
    let app: XCUIApplication

    static func launch() throws -> TestHarness {
        let appBundle = try locateAppBundle()
        let config = NSWorkspace.OpenConfiguration()
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

        // Fixture thread appearing proves Spindle connection + sync completed
        let fixtureRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'thread.row.' AND label CONTAINS 'test-xcui'")
        ).firstMatch
        guard fixtureRow.waitForExistence(timeout: 10) else {
            app.terminate()
            throw UITestError("Fixture thread not found in sidebar — is Spindle running?")
        }

        return TestHarness(app: app)
    }

    func tearDown() {
        app.terminate()
    }

    // MARK: - Helpers

    func waitForFixtureThread(timeout: TimeInterval = 0.5) -> XCUIElement? {
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'thread.row.' AND label CONTAINS 'test-xcui'")
        ).firstMatch
        return row.waitForExistence(timeout: timeout) ? row : nil
    }

    func selectMode(_ modeID: String, timeout: TimeInterval = 0.5) throws {
        let tab = app.descendants(matching: .any).matching(identifier: modeID).firstMatch
        guard tab.waitForExistence(timeout: timeout) else {
            throw UITestError("Mode tab \(modeID) not found")
        }
        tab.click()
    }

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
        throw UITestError("Threadmill.app not found — run: task build")
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

struct UITestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
