import XCTest
@testable import Threadmill

final class RepoAvatarTests: XCTestCase {
    func testRepoAvatarUsesStableLetterAndPaletteIndex() {
        let repo = Repo(
            id: "repo-1",
            owner: "anomalyco",
            name: "threadmill",
            fullName: "anomalyco/threadmill",
            cloneURL: "git@github.com:anomalyco/threadmill.git",
            defaultBranch: "main",
            isPrivate: true,
            cachedAt: .now
        )
        let sameNameRepo = Repo(
            id: "repo-2",
            owner: "anomalyco",
            name: "threadmill",
            fullName: "anomalyco/threadmill-fork",
            cloneURL: "git@github.com:anomalyco/threadmill-fork.git",
            defaultBranch: "main",
            isPrivate: false,
            cachedAt: .now
        )

        XCTAssertEqual(repo.avatarLetter, "T")
        XCTAssertEqual(repo.avatarColorIndex, sameNameRepo.avatarColorIndex)
        XCTAssertTrue((0..<10).contains(repo.avatarColorIndex))
    }
}
