import Foundation
import XCTest

final class SessionTabsScrollViewSourceTests: XCTestCase {
    func testNewTabButtonUsesSplitPlusAndHarnessMenuChevron() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Views/Components/SessionTabsScrollView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("Image(systemName: \"plus\")"))
        XCTAssertTrue(source.contains("Image(systemName: \"chevron.down\")"))
        XCTAssertFalse(source.contains("primaryAction:"))
    }

    func testSessionTabButtonRestoresButtonAccessibilityTraits() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Views/Components/SessionTabsScrollView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains(".onTapGesture(perform: action)"))
        XCTAssertTrue(source.contains(".contentShape(Capsule())"))
    }
}
