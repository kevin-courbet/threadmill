import Foundation
import XCTest

/// Tests terminal preset behavior:
/// - The + button creates multiple independent terminal sessions
/// - The dropdown menu offers named presets (e.g. dev-server)
///
/// Uses RealSpindleHarness — real app, real Spindle, UI-only assertions.
@MainActor
final class TerminalPresetBehaviorTests: XCTestCase {
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

    // MARK: - Test: + button creates 3 independent terminals

    func testPlusButtonCreatesThreeTerminals() throws {
        guard let harness else { throw XCTSkip("Harness not available") }

        guard let threadRow = harness.waitForFixtureThread(timeout: 10) else {
            XCTFail("Fixture thread not found")
            return
        }
        threadRow.click()

        // Switch to Terminal mode — first terminal auto-starts
        try harness.selectMode("mode.tab.terminal")

        let surface = harness.app.descendants(matching: .any)
            .matching(identifier: "terminal.surface").firstMatch
        guard surface.waitForExistence(timeout: 10) else {
            harness.screenshot(name: "first-terminal-missing", testCase: self)
            XCTFail("First terminal surface did not appear")
            return
        }

        let addButton = harness.app.descendants(matching: .any)
            .matching(identifier: "terminal.session.add").firstMatch
        guard addButton.waitForExistence(timeout: 5) else {
            XCTFail("terminal.session.add button not found")
            return
        }

        // Click + twice to create terminals 2 and 3
        addButton.click()
        Thread.sleep(forTimeInterval: 1)
        addButton.click()
        Thread.sleep(forTimeInterval: 2)

        // Verify 3 session tabs exist
        let sessionTabs = harness.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session.tab.' AND NOT identifier BEGINSWITH 'session.tab.close.'"))
        XCTAssertGreaterThanOrEqual(sessionTabs.count, 3,
                                    "Should have at least 3 terminal session tabs after clicking + twice")

        harness.screenshot(name: "three-terminals", testCase: self)
    }

    // MARK: - Test: Dropdown opens named preset

    func testDropdownOpensDevServer() throws {
        guard let harness else { throw XCTSkip("Harness not available") }

        guard let threadRow = harness.waitForFixtureThread(timeout: 10) else {
            XCTFail("Fixture thread not found")
            return
        }
        threadRow.click()

        // Switch to Terminal mode
        try harness.selectMode("mode.tab.terminal")

        let surface = harness.app.descendants(matching: .any)
            .matching(identifier: "terminal.surface").firstMatch
        guard surface.waitForExistence(timeout: 10) else {
            harness.screenshot(name: "terminal-not-loaded", testCase: self)
            XCTFail("Terminal surface did not appear")
            return
        }

        // Open the dropdown menu
        let menuButton = harness.app.descendants(matching: .any)
            .matching(identifier: "terminal.session.add.menu").firstMatch
        guard menuButton.waitForExistence(timeout: 5) else {
            harness.screenshot(name: "no-menu-button", testCase: self)
            XCTFail("terminal.session.add.menu button not found")
            return
        }
        menuButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Click the dev-server preset item
        let devServerItem = harness.app.descendants(matching: .any)
            .matching(identifier: "terminal.session.add.item.dev-server").firstMatch
        guard devServerItem.waitForExistence(timeout: 5) else {
            harness.screenshot(name: "no-dev-server-item", testCase: self)
            XCTFail("terminal.session.add.item.dev-server not found in dropdown")
            return
        }
        devServerItem.click()

        // Wait for the dev-server session tab to appear
        Thread.sleep(forTimeInterval: 2)
        let devServerTab = harness.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session.tab.' AND label CONTAINS[c] 'dev-server'"))
            .firstMatch
        XCTAssertTrue(devServerTab.waitForExistence(timeout: 5),
                      "Session tab for dev-server preset should appear")

        harness.screenshot(name: "dev-server-opened", testCase: self)
    }
}
