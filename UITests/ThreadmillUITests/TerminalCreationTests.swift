import Foundation
import XCTest

/// Tests that terminal sessions are created and visible across thread switches.
///
/// Uses RealSpindleHarness — real app, real Spindle, UI-only assertions.
@MainActor
final class TerminalCreationTests: XCTestCase {
    private var harness: RealSpindleHarness?

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try RealSpindleHarness.launch()
    }

    override func tearDownWithError() throws {
        harness?.tearDown()
        harness = nil
        try super.tearDownWithError()
    }

    func testCreatesMultipleTerminalSessions() throws {
        guard let harness else { throw XCTSkip("Harness not available") }

        // Find and click the fixture thread
        guard let threadRow = harness.waitForFixtureThread(timeout: 10) else {
            harness.screenshot(name: "no-fixture-thread", testCase: self)
            XCTFail("Fixture thread (test-xcui-*) not found in sidebar")
            return
        }
        threadRow.click()

        // Switch to Terminal mode — first terminal auto-starts
        try harness.selectMode("mode.tab.terminal")

        let surface = harness.app.descendants(matching: .any)
            .matching(identifier: "terminal.surface").firstMatch
        guard surface.waitForExistence(timeout: 10) else {
            harness.screenshot(name: "first-terminal-not-loaded", testCase: self)
            XCTFail("First terminal surface did not appear")
            return
        }

        // Click + to create a second terminal session
        let addButton = harness.app.descendants(matching: .any)
            .matching(identifier: "terminal.session.add").firstMatch
        guard addButton.waitForExistence(timeout: 5) else {
            harness.screenshot(name: "no-add-button", testCase: self)
            XCTFail("terminal.session.add button not found")
            return
        }
        addButton.click()

        // Wait for the second session tab to appear
        Thread.sleep(forTimeInterval: 2)

        // Verify we have at least 2 session tabs
        let sessionTabs = harness.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session.tab.' AND NOT identifier BEGINSWITH 'session.tab.close.'"))
        XCTAssertGreaterThanOrEqual(sessionTabs.count, 2,
                                    "Should have at least 2 terminal session tabs")

        harness.screenshot(name: "two-terminal-sessions", testCase: self)
    }
}
