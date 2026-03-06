import XCTest
@testable import Threadmill

@MainActor
final class SidebarNewThreadFlowTests: XCTestCase {
    func testPerRepoNewThreadActionPreselectsRepoInSheet() {
        let repo = Repo(
            id: "repo-2",
            owner: "anomalyco",
            name: "threadmill",
            fullName: "anomalyco/threadmill",
            cloneURL: "git@github.com:anomalyco/threadmill.git",
            defaultBranch: "main",
            isPrivate: true,
            cachedAt: Date(timeIntervalSince1970: 1)
        )
        var newThreadRepo: Repo?
        let onNewThread: (Repo) -> Void = { tappedRepo in
            newThreadRepo = tappedRepo
        }

        onNewThread(repo)
        let sheet = NewThreadSheet(repo: newThreadRepo!)

        XCTAssertEqual(sheet.repo.id, repo.id)
    }
}
