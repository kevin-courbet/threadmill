import Foundation
import XCTest

/// Regression test: new terminal must show the shell prompt without pressing Enter.
///
/// Uses RealSpindleHarness — fresh DB with only fixture data visible.
/// Fixture thread pre-created by Scripts/setup_xcui_fixture.swift.
@MainActor
final class TerminalPromptTests: XCTestCase {
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

    func testNewTerminalShowsPromptWithoutEnterPress() throws {
        guard let harness else { throw XCTSkip("Harness not available") }

        // Find and click the fixture thread
        guard let threadRow = harness.waitForFixtureThread(timeout: 10) else {
            harness.screenshot(name: "no-fixture-thread", testCase: self)
            XCTFail("Fixture thread (test-xcui-*) not found in sidebar")
            return
        }
        threadRow.click()

        // Switch to Terminal mode
        try harness.selectMode("mode.tab.terminal")

        // Wait for terminal.connecting to disappear and terminal.surface to appear
        let terminalView = harness.app.descendants(matching: .any)
            .matching(identifier: "terminal.surface").firstMatch
        guard terminalView.waitForExistence(timeout: 10) else {
            harness.screenshot(name: "terminal-not-loaded", testCase: self)
            // Check if still connecting
            let connecting = harness.app.staticTexts.matching(identifier: "terminal.connecting").firstMatch
            if connecting.exists {
                XCTFail("Terminal still in 'connecting' state after 10s")
            } else {
                XCTFail("terminal.surface never appeared")
            }
            return
        }

        // Surface appeared — wait a moment for content to render
        Thread.sleep(forTimeInterval: 2)
        harness.screenshot(name: "terminal-before-enter", testCase: self)

        if terminalView.exists {
            let text = terminalView.value as? String ?? ""
            let hasPrompt = text.contains("❯") || text.contains("$")
                || text.contains("%") || text.contains("via ")
            XCTAssertTrue(hasPrompt, "Terminal visible but no prompt. Got: \(text.prefix(300))")
        } else {
            // terminal.surface not found — check what IS visible
            // Look for "Starting terminal" text which means the terminal hasn't loaded
            let startingText = harness.app.staticTexts["Starting terminal…"].firstMatch
            if startingText.exists {
                XCTFail("Terminal is still showing 'Starting terminal…' — attach may have failed")
            } else {
                // Dump what we can see
                let textAreas = harness.app.textViews.allElementsBoundByIndex
                let texts = harness.app.staticTexts.allElementsBoundByIndex
                let dump = (textAreas.prefix(5).map { "textArea: [\($0.identifier)] '\($0.value as? String ?? "")'" }
                    + texts.prefix(10).map { "text: [\($0.identifier)] '\($0.label)'" })
                    .joined(separator: "\n")
                XCTFail("terminal.surface not found.\n\(dump)")
            }
        }
    }
}
