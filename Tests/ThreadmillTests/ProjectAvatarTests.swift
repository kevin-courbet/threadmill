import XCTest
@testable import Threadmill

final class ProjectAvatarTests: XCTestCase {
    func testProjectAvatarUsesStableLetterAndPaletteIndex() {
        let project = Project(
            id: "project-1",
            name: "myautonomy",
            remotePath: "/tmp/myautonomy",
            defaultBranch: "main"
        )
        let sameNameProject = Project(
            id: "project-2",
            name: "myautonomy",
            remotePath: "/tmp/another",
            defaultBranch: "main"
        )

        XCTAssertEqual(project.avatarLetter, "M")
        XCTAssertEqual(project.avatarColorIndex, sameNameProject.avatarColorIndex)
        XCTAssertTrue((0..<10).contains(project.avatarColorIndex))
    }
}
