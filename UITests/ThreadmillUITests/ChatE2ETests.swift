import Foundation
import XCTest

/// Chat XCUI e2e tests — real app + real Spindle.
@MainActor
final class ChatE2ETests: XCTestCase {
    private static let launchTimeout: TimeInterval = 10
    private static let uiTimeout: TimeInterval = 2
    private static let responseTimeout: TimeInterval = 90

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

    private func navigateToChatMode() throws -> TestHarness {
        let h = try ensureHarness()
        guard let threadRow = h.waitForFixtureThread(timeout: Self.launchTimeout) else {
            h.screenshot(name: "chat-no-fixture-thread", testCase: self)
            XCTFail("Fixture thread not found in sidebar")
            throw UITestError("Fixture thread not found")
        }
        threadRow.click()
        h.screenshot(name: "chat-step-01-thread-selected", testCase: self)

        try h.selectMode("mode.tab.chat", timeout: Self.uiTimeout)
        h.screenshot(name: "chat-step-02-chat-mode", testCase: self)
        return h
    }

    func test01_ChatSessionSendAndReceive() throws {
        let h = try navigateToChatMode()

        try ensureChatSessionExists(h)
        h.screenshot(name: "chat-step-03-session-ready", testCase: self)

        let modelLabel = h.app.descendants(matching: .any).matching(identifier: "chat.model.label").firstMatch
        XCTAssertTrue(modelLabel.waitForExistence(timeout: Self.uiTimeout), "chat.model.label not found")
        let selectedModel = modelLabel.label.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(selectedModel.isEmpty)
        XCTAssertNotEqual(selectedModel, "Model")
        h.screenshot(name: "chat-step-04-model-visible", testCase: self)

        let timeline = h.app.descendants(matching: .any).matching(identifier: "chat.timeline").firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: Self.uiTimeout), "chat.timeline not found")
        let baselineTextCount = timeline.descendants(matching: .staticText).count

        let input = h.app.descendants(matching: .any).matching(identifier: "chat.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: Self.uiTimeout), "chat.input not found")
        input.click()

        let nonce = String(UUID().uuidString.prefix(8))
        let prompt = "Reply with exactly ACK-\(nonce)."
        input.typeText(prompt)
        input.typeText("\r")
        h.screenshot(name: "chat-step-05-prompt-sent", testCase: self)

        let timelineUpdated = NSPredicate { _, _ in
            let currentCount = timeline.descendants(matching: .staticText).count
            return currentCount >= baselineTextCount + 2
        }
        let expectation = XCTNSPredicateExpectation(predicate: timelineUpdated, object: nil)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: Self.responseTimeout),
            .completed,
            "Expected agent response to append timeline entries"
        )

        h.screenshot(name: "chat-step-06-agent-response", testCase: self)
    }

    private func ensureChatSessionExists(_ h: TestHarness) throws {
        let sessionState = h.app.descendants(matching: .any).matching(identifier: "chat.session.state").firstMatch
        if !sessionState.waitForExistence(timeout: Self.uiTimeout) {
            let addButton = h.app.descendants(matching: .any).matching(identifier: "chat.session.add").firstMatch
            XCTAssertTrue(addButton.waitForExistence(timeout: Self.uiTimeout), "chat.session.add not found")
            addButton.click()
            h.screenshot(name: "chat-step-03a-session-created", testCase: self)
            XCTAssertTrue(sessionState.waitForExistence(timeout: Self.launchTimeout), "chat.session.state missing after creating session")
        }

        let readyPredicate = NSPredicate(format: "value CONTAINS[c] 'ready'")
        let readyExpectation = XCTNSPredicateExpectation(predicate: readyPredicate, object: sessionState)
        XCTAssertEqual(
            XCTWaiter().wait(for: [readyExpectation], timeout: Self.responseTimeout),
            .completed,
            "Chat session did not become ready"
        )
    }
}
