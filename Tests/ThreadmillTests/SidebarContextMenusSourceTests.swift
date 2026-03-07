import Foundation
import XCTest

final class SidebarContextMenusSourceTests: XCTestCase {
    func testSidebarSectionsDefineContextMenusWithDestructiveConfirmations() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let repoSectionSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Repos/RepoSection.swift"),
            encoding: .utf8
        )
        let projectSectionSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Projects/ProjectSection.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(repoSectionSource.contains("Button(\"Remove Repository\", role: .destructive)"))
        XCTAssertTrue(projectSectionSource.contains("Button(\"Remove Repository\", role: .destructive)"))
        XCTAssertTrue(repoSectionSource.contains("Button(\"Close Thread\", role: .destructive)"))
        XCTAssertTrue(projectSectionSource.contains("Button(\"Close Thread\", role: .destructive)"))
        XCTAssertTrue(repoSectionSource.contains("Close Thread?"))
        XCTAssertTrue(projectSectionSource.contains("Close Thread?"))
    }
}
