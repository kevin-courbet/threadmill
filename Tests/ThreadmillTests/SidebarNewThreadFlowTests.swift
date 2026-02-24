import XCTest
@testable import Threadmill

@MainActor
final class SidebarNewThreadFlowTests: XCTestCase {
    func testPerProjectNewThreadActionPreselectsProjectInSheet() {
        let project = Project(
            id: "project-2",
            name: "Demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main"
        )
        var newThreadProjectID: String?
        let onNewThread: (Project) -> Void = { tappedProject in
            newThreadProjectID = preselectedProjectIDForNewThread(from: tappedProject)
        }

        onNewThread(project)
        let sheet = NewThreadSheet(preselectedProjectID: newThreadProjectID)

        XCTAssertEqual(sheet.preselectedProjectID, project.id)
    }
}
