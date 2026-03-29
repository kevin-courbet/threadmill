import Foundation
import XCTest

@MainActor
final class ChatE2ETests: XCTestCase {
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

    func test01_ChatSessionSendAndReceive() throws {
        let h = try ensureHarness()

        try h.selectMode("mode.tab.chat")

        // Create a fresh session — never rely on stale GRDB state
        let addButton = h.app.descendants(matching: .any)
            .matching(identifier: "chat.session.add").firstMatch
        guard addButton.waitForExistence(timeout: 3) else {
            h.screenshot(name: "chat-no-add", testCase: self)
            throw UITestError("chat.session.add not found")
        }
        addButton.click()

        // Wait for input to become interactive (session start + handshake + attach)
        let input = h.app.descendants(matching: .any)
            .matching(identifier: "chat.input").firstMatch
        guard input.waitForExistence(timeout: 5) else {
            h.screenshot(name: "chat-no-input", testCase: self)
            throw UITestError("chat.input not found")
        }

        Thread.sleep(forTimeInterval: 3.0)
        input.click()
        Thread.sleep(forTimeInterval: 0.1)
        h.screenshot(name: "chat-01-ready", testCase: self)

        // Send prompt
        let nonce = String(UUID().uuidString.prefix(8))
        input.typeText("Reply with exactly one word: ACK-\(nonce)")
        input.typeText("\r")
        h.screenshot(name: "chat-02-sent", testCase: self)

        // Search all timeline descendants for response
        let timeline = h.app.descendants(matching: .any)
            .matching(identifier: "chat.timeline").firstMatch

        var found = false
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if timeline.exists {
                let all = timeline.descendants(matching: .any)
                for i in 0..<min(all.count, 200) {
                    let el = all.element(boundBy: i)
                    if el.exists {
                        let value = el.value as? String ?? ""
                        if value.contains("ACK-\(nonce)") {
                            found = true
                            break
                        }
                    }
                }
            }
            if found { break }
            Thread.sleep(forTimeInterval: 0.5)
        }

        h.screenshot(name: "chat-03-response", testCase: self)
        XCTAssertTrue(found, "Agent response with ACK-\(nonce) not found within 10s")
    }
}
