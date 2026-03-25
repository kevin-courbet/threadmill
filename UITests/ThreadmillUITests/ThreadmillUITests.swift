import Foundation
import XCTest

/// All XCUI e2e tests — single class, shared app instance.
///
/// Launches the real app against real Spindle on beast. Tests find the fixture
/// thread (test-xcui-*) in the sidebar and interact with it.
///
/// On failure, filter Console.app with `subsystem:dev.threadmill` for diagnostics.
@MainActor
final class ThreadmillUITests: XCTestCase {
    /// All actions must complete within this. No exceptions.
    private static let timeout: TimeInterval = 0.5

    private static var harness: TestHarness?
    private static var launchAttempted = false

    private func ensureHarness() throws -> TestHarness {
        if let h = Self.harness { return h }
        guard !Self.launchAttempted else { throw XCTSkip("Harness launch previously failed") }
        Self.launchAttempted = true
        let h = try TestHarness.launch()
        Self.harness = h
        return h
    }

    private func navigateToTerminalMode() throws -> TestHarness {
        let h = try ensureHarness()
        guard let threadRow = h.waitForFixtureThread(timeout: Self.timeout) else {
            h.screenshot(name: "no-fixture-thread", testCase: self)
            XCTFail("Fixture thread not found in sidebar")
            throw UITestError("Fixture thread not found")
        }
        threadRow.click()
        try h.selectMode("mode.tab.terminal")
        return h
    }

    /// Select terminal-1 session tab. Terminal-1 is auto-created when terminal
    /// mode activates. If another session (e.g. dev-server from @AppStorage) is
    /// selected, this explicitly switches to terminal-1.
    private func selectTerminal1(_ h: TestHarness) {
        // Click the StaticText "Terminal 1" — the AXButton with same ID is the close button
        let tab = h.app.staticTexts.matching(identifier: "session.tab.terminal-1").firstMatch
        guard tab.waitForExistence(timeout: Self.timeout) else {
            XCTFail("session.tab.terminal-1 not found")
            return
        }
        tab.click()
    }

    private func waitForTerminalSurface(_ h: TestHarness, label: String) -> XCUIElement? {
        let surface = h.app.descendants(matching: .any)
            .matching(identifier: "terminal.surface").firstMatch
        // terminal.surface should exist almost immediately after mode switch;
        // rpcTimeout covers the attach RPC round-trip on first connect.
        guard surface.waitForExistence(timeout: Self.timeout) else {
            h.screenshot(name: "\(label)-not-loaded", testCase: self)
            let connecting = h.app.staticTexts.matching(identifier: "terminal.connecting").firstMatch
            if connecting.exists {
                XCTFail("\(label): Terminal stuck in 'connecting'")
            } else {
                XCTFail("\(label): terminal.surface never appeared")
            }
            return nil
        }
        return surface
    }

    // MARK: - Terminal Prompt

    func test01_TerminalShowsPromptWithoutInteraction() throws {
        let h = try navigateToTerminalMode()
        selectTerminal1(h)
        guard let surface = waitForTerminalSurface(h, label: "prompt") else { return }

        // Debug: log raw accessibility value before and after wait
        let text = surface.value as? String ?? ""
        let hasPrompt = text.contains("❯") || text.contains("$")
            || text.contains("%") || text.contains("via ")
        XCTAssertTrue(hasPrompt, "Prompt not found. Got (\(text.count) chars): \(text.prefix(200))")
        h.screenshot(name: "terminal-prompt", testCase: self)

        h.screenshot(name: "terminal-prompt", testCase: self)
    }

    // MARK: - Terminal Session Creation

    func test02_PlusButtonCreatesAdditionalTerminal() throws {
        let h = try navigateToTerminalMode()
        guard waitForTerminalSurface(h, label: "creation") != nil else { return }

        let addButton = h.app.descendants(matching: .any)
            .matching(identifier: "terminal.session.add").firstMatch
        guard addButton.waitForExistence(timeout: Self.timeout) else {
            XCTFail("terminal.session.add button not found")
            return
        }
        addButton.click()

        // New tab appears after preset.start RPC
        let newTab = h.app.descendants(matching: .any)
            .matching(NSPredicate(format:
                "identifier BEGINSWITH 'session.tab.terminal-' AND NOT identifier BEGINSWITH 'session.tab.close.'"
            )).element(boundBy: 1) // second terminal-* tab
        XCTAssertTrue(newTab.waitForExistence(timeout: Self.timeout),
                      "Second terminal session tab should appear")
        h.screenshot(name: "two-terminals", testCase: self)
    }

    // MARK: - Named Preset via Dropdown

    func test03_DropdownOpensDevServer() throws {
        let h = try navigateToTerminalMode()
        guard waitForTerminalSurface(h, label: "dropdown") != nil else { return }

        let menuButton = h.app.descendants(matching: .any)
            .matching(identifier: "terminal.session.add.menu").firstMatch
        guard menuButton.waitForExistence(timeout: Self.timeout) else {
            h.screenshot(name: "no-menu-button", testCase: self)
            XCTFail("terminal.session.add.menu not found")
            return
        }
        menuButton.click()

        let devServerItem = h.app.descendants(matching: .any)
            .matching(identifier: "terminal.session.add.item.dev-server").firstMatch
        guard devServerItem.waitForExistence(timeout: Self.timeout) else {
            h.screenshot(name: "no-dev-server-item", testCase: self)
            XCTFail("dev-server preset not found in dropdown")
            return
        }
        devServerItem.click()

        let devServerTab = h.app.descendants(matching: .any)
            .matching(identifier: "session.tab.dev-server").firstMatch
        XCTAssertTrue(devServerTab.waitForExistence(timeout: Self.timeout),
                      "dev-server session tab should appear")
        h.screenshot(name: "dev-server-opened", testCase: self)
    }
}
