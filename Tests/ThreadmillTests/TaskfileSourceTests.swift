import Foundation
import XCTest

final class TaskfileSourceTests: XCTestCase {
    func testUITaskUsesXcodebuildProjectRunner() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let taskfilePath = repositoryRoot.appendingPathComponent("Taskfile.yml")
        let source = try String(contentsOf: taskfilePath, encoding: .utf8)

        XCTAssertTrue(source.contains("xcodebuild test -project UITests/ThreadmillUITests.xcodeproj -scheme ThreadmillUITests -destination 'platform=macOS'"))
        XCTAssertFalse(source.contains("swift test --filter ThreadmillUITests"))
    }
}
