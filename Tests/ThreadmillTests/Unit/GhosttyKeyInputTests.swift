import XCTest
@testable import Threadmill

@MainActor
final class GhosttyKeyInputTests: XCTestCase {
    func testDELCharacterIsTreatedAsControlInput() {
        XCTAssertFalse(GhosttyKeyInput.shouldSendText("\u{7f}"))
    }
}
