import Foundation
import XCTest
@testable import Threadmill

@MainActor
final class DatabaseRepoTests: XCTestCase {
    func testRepoRoundTripSaveFetchDelete() throws {
        let dbPath = try makeTempDatabasePath()
        let database = try DatabaseManager(databasePath: dbPath)

        let repo = Repo(
            id: UUID().uuidString,
            owner: "anomalyco",
            name: "threadmill",
            fullName: "anomalyco/threadmill",
            cloneURL: "git@github.com:anomalyco/threadmill.git",
            defaultBranch: "main",
            isPrivate: true,
            cachedAt: Date(timeIntervalSince1970: 1)
        )

        try database.saveRepo(repo)

        XCTAssertEqual(try database.repo(id: repo.id), repo)
        XCTAssertEqual(try database.allRepos(), [repo])

        try database.deleteRepo(id: repo.id)

        XCTAssertNil(try database.repo(id: repo.id))
    }

    func testMigrationV7AddsProjectRepoIDColumn() throws {
        let dbPath = try makeTempDatabasePath()
        let database = try DatabaseManager(databasePath: dbPath)

        let repo = Repo(
            id: "repo-1",
            owner: "anomalyco",
            name: "threadmill",
            fullName: "anomalyco/threadmill",
            cloneURL: "git@github.com:anomalyco/threadmill.git",
            defaultBranch: "main",
            isPrivate: false,
            cachedAt: Date(timeIntervalSince1970: 1)
        )
        try database.saveRepo(repo)

        let project = Project(
            id: "project-1",
            name: "threadmill",
            remotePath: "/home/wsl/dev/threadmill",
            defaultBranch: "main",
            presets: [],
            remoteId: nil,
            repoId: repo.id
        )

        let remoteID = try XCTUnwrap(try database.allRemotes().first?.id)
        try database.replaceAllFromDaemon(projects: [project], threads: [], remoteId: remoteID)

        XCTAssertEqual(try database.allProjects().first?.repoId, repo.id)
    }

    func testReplaceAllFromDaemonPreservesOtherRemoteData() throws {
        let dbPath = try makeTempDatabasePath()
        let database = try DatabaseManager(databasePath: dbPath)

        let remoteA = Remote(
            id: "remote-a",
            name: "remote-a",
            host: "remote-a-host",
            daemonPort: 21001,
            useSSHTunnel: true,
            cloneRoot: "/srv/remote-a"
        )
        let remoteB = Remote(
            id: "remote-b",
            name: "remote-b",
            host: "remote-b-host",
            daemonPort: 21002,
            useSSHTunnel: true,
            cloneRoot: "/srv/remote-b"
        )
        try database.saveRemote(remoteA)
        try database.saveRemote(remoteB)

        try database.saveRepo(
            Repo(
                id: "repo-a",
                owner: "anomalyco",
                name: "alpha",
                fullName: "anomalyco/alpha",
                cloneURL: "git@github.com:anomalyco/alpha.git",
                defaultBranch: "main",
                isPrivate: false,
                cachedAt: Date(timeIntervalSince1970: 1)
            )
        )
        try database.saveRepo(
            Repo(
                id: "repo-b",
                owner: "anomalyco",
                name: "beta",
                fullName: "anomalyco/beta",
                cloneURL: "git@github.com:anomalyco/beta.git",
                defaultBranch: "main",
                isPrivate: false,
                cachedAt: Date(timeIntervalSince1970: 1)
            )
        )

        let projectA = Project(
            id: "project-a",
            name: "alpha",
            remotePath: "/srv/remote-a/alpha",
            defaultBranch: "main",
            presets: [],
            remoteId: remoteA.id,
            repoId: "repo-a"
        )
        let projectB = Project(
            id: "project-b",
            name: "beta",
            remotePath: "/srv/remote-b/beta",
            defaultBranch: "main",
            presets: [],
            remoteId: remoteB.id,
            repoId: "repo-b"
        )

        let threadA = ThreadModel(
            id: "thread-a",
            projectId: projectA.id,
            name: "alpha-work",
            branch: "feature/alpha",
            worktreePath: "/srv/remote-a/.threadmill/alpha-work",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 10),
            tmuxSession: "tmux-a",
            portOffset: 0
        )
        let threadB = ThreadModel(
            id: "thread-b",
            projectId: projectB.id,
            name: "beta-work",
            branch: "feature/beta",
            worktreePath: "/srv/remote-b/.threadmill/beta-work",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 20),
            tmuxSession: "tmux-b",
            portOffset: 20
        )

        try database.replaceAllFromDaemon(projects: [projectA], threads: [threadA], remoteId: remoteA.id)
        try database.replaceAllFromDaemon(projects: [projectB], threads: [threadB], remoteId: remoteB.id)

        let refreshedProjectA = Project(
            id: projectA.id,
            name: "alpha-updated",
            remotePath: projectA.remotePath,
            defaultBranch: "main",
            presets: [],
            remoteId: nil,
            repoId: nil
        )
        let refreshedThreadA = ThreadModel(
            id: "thread-a-2",
            projectId: projectA.id,
            name: "alpha-work-2",
            branch: "feature/alpha-2",
            worktreePath: "/srv/remote-a/.threadmill/alpha-work-2",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 30),
            tmuxSession: "tmux-a-2",
            portOffset: 40
        )

        try database.replaceAllFromDaemon(projects: [refreshedProjectA], threads: [refreshedThreadA], remoteId: remoteA.id)

        let projects = try database.allProjects()
        XCTAssertEqual(Set(projects.map(\.id)), Set([projectA.id, projectB.id]))

        let persistedProjectA = try XCTUnwrap(projects.first(where: { $0.id == projectA.id }))
        XCTAssertEqual(persistedProjectA.remoteId, remoteA.id)
        XCTAssertEqual(persistedProjectA.repoId, projectA.repoId)

        let persistedProjectB = try XCTUnwrap(projects.first(where: { $0.id == projectB.id }))
        XCTAssertEqual(persistedProjectB.remoteId, remoteB.id)
        XCTAssertEqual(persistedProjectB.repoId, projectB.repoId)

        let threads = try database.allThreads()
        XCTAssertTrue(threads.contains(where: { $0.id == threadB.id }))
    }

    func testReplaceAllFromDaemonDoesNotDeleteSharedProjectThreadsFromAnotherRemote() throws {
        let dbPath = try makeTempDatabasePath()
        let database = try DatabaseManager(databasePath: dbPath)

        let remoteA = Remote(
            id: "remote-a",
            name: "remote-a",
            host: "remote-a-host",
            daemonPort: 21001,
            useSSHTunnel: true,
            cloneRoot: "/srv/remote-a"
        )
        let remoteB = Remote(
            id: "remote-b",
            name: "remote-b",
            host: "remote-b-host",
            daemonPort: 21002,
            useSSHTunnel: true,
            cloneRoot: "/srv/remote-b"
        )
        try database.saveRemote(remoteA)
        try database.saveRemote(remoteB)

        let sharedProjectID = "project-shared"
        let projectFromRemoteA = Project(
            id: sharedProjectID,
            name: "alpha",
            remotePath: "/srv/remote-a/alpha",
            defaultBranch: "main",
            presets: [],
            remoteId: remoteA.id,
            repoId: nil
        )
        let threadFromRemoteA = ThreadModel(
            id: "thread-a",
            projectId: sharedProjectID,
            name: "alpha-work",
            branch: "feature/alpha",
            worktreePath: "/srv/remote-a/.threadmill/alpha-work",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 10),
            tmuxSession: "tmux-a",
            portOffset: 0
        )

        try database.replaceAllFromDaemon(projects: [projectFromRemoteA], threads: [threadFromRemoteA], remoteId: remoteA.id)

        let projectFromRemoteB = Project(
            id: sharedProjectID,
            name: "beta",
            remotePath: "/srv/remote-b/beta",
            defaultBranch: "main",
            presets: [],
            remoteId: nil,
            repoId: nil
        )
        let threadFromRemoteB = ThreadModel(
            id: "thread-b",
            projectId: sharedProjectID,
            name: "beta-work",
            branch: "feature/beta",
            worktreePath: "/srv/remote-b/.threadmill/beta-work",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 20),
            tmuxSession: "tmux-b",
            portOffset: 20
        )

        try database.replaceAllFromDaemon(projects: [projectFromRemoteB], threads: [threadFromRemoteB], remoteId: remoteB.id)

        let threads = try database.allThreads()
        XCTAssertTrue(threads.contains(where: { $0.id == threadFromRemoteA.id }))
        XCTAssertTrue(threads.contains(where: { $0.id == threadFromRemoteB.id }))
    }

    private func makeTempDatabasePath() throws -> String {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threadmill-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return baseDirectory.appendingPathComponent("threadmill.db", isDirectory: false).path
    }
}
