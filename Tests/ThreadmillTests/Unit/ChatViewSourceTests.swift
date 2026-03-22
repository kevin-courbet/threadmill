import Foundation
import XCTest

final class ChatViewSourceTests: XCTestCase {
    func testChatSessionViewUsesMessageListAndInputBar() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Chat/ChatSessionView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("VStack(spacing: 0)"))
        XCTAssertTrue(source.contains("ChatMessageList"))
        XCTAssertTrue(source.contains("ChatInputBar"))
    }
}
