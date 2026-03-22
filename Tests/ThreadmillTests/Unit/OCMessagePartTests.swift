import Foundation
import XCTest
@testable import Threadmill

final class OCMessagePartTests: XCTestCase {
    func testMessagePartDecodesTextField() throws {
        let payload = """
        {
          "id": "part_1",
          "type": "reasoning",
          "sessionID": "ses_1",
          "messageID": "msg_1",
          "text": "I should inspect the files before editing."
        }
        """.data(using: .utf8)!

        let part = try JSONDecoder().decode(OCMessagePart.self, from: payload)

        XCTAssertEqual(part.text, "I should inspect the files before editing.")
    }
}
