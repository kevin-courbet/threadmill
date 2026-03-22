import XCTest
@testable import Threadmill

final class OpenCodeClientTests: XCTestCase {
    func testOpenCodeClientOperationsThrowUnavailable() async {
        let client = OpenCodeClient()

        await XCTAssertThrowsErrorAsync {
            _ = try await client.createSession(directory: "/tmp/worktree")
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await client.listSessions(directory: "/tmp/worktree")
        }
    }

    func testMockOpenCodeClientStillRecordsPromptCalls() async throws {
        let mock = MockOpenCodeClient()
        try await mock.sendPrompt(sessionID: "ses_1", prompt: "Hello", directory: "/tmp/worktree")

        XCTAssertEqual(mock.promptedSessions.count, 1)
        XCTAssertEqual(mock.promptedSessions.first?.sessionID, "ses_1")
        XCTAssertEqual(mock.promptedSessions.first?.prompt, "Hello")
    }
}

private func XCTAssertThrowsErrorAsync(
    _ operation: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
