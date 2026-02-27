import XCTest
@testable import Threadmill

final class ProjectSectionTests: XCTestCase {
    func testInstantToggleTransactionDisablesAnimations() {
        let transaction = instantToggleTransaction()

        XCTAssertTrue(transaction.disablesAnimations)
        XCTAssertNil(transaction.animation)
    }
}
