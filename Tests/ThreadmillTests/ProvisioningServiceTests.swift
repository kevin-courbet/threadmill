import XCTest
@testable import Threadmill

@MainActor
final class ProvisioningServiceTests: XCTestCase {
    func testEnsureRepoOnRemoteReturnsExistingRegisteredProjectID() async throws {
        let remote = makeRemote()
        let repo = makeRepo()
        let connection = MockDaemonConnection(state: .connected)
        let pool = MockRemoteConnectionPool()
        pool.connections[remote.id] = connection

        connection.requestHandler = { method, _, _ in
            switch method {
            case "project.lookup":
                return [
                    "exists": true,
                    "is_git_repo": true,
                    "project_id": "project-1",
                ]
            default:
                throw TestError.missingStub
            }
        }

        let service = ProvisioningService(connectionPool: pool)
        let projectID = try await service.ensureRepoOnRemote(repo: repo, remote: remote)

        XCTAssertEqual(projectID, "project-1")
        XCTAssertEqual(pool.ensuredRemoteIDs, [remote.id])
        XCTAssertEqual(connection.requests.map(\.method), ["project.lookup"])
        XCTAssertEqual(connection.requests.first?.params?["path"] as? String, "/home/wsl/dev/anomalyco/threadmill")
    }

    func testEnsureRepoOnRemoteRegistersExistingGitRepository() async throws {
        let remote = makeRemote()
        let repo = makeRepo()
        let connection = MockDaemonConnection(state: .connected)
        let pool = MockRemoteConnectionPool()
        pool.connections[remote.id] = connection

        connection.requestHandler = { method, _, _ in
            switch method {
            case "project.lookup":
                return [
                    "exists": true,
                    "is_git_repo": true,
                    "project_id": NSNull(),
                ]
            case "project.add":
                return ["id": "project-2"]
            default:
                throw TestError.missingStub
            }
        }

        let service = ProvisioningService(connectionPool: pool)
        let projectID = try await service.ensureRepoOnRemote(repo: repo, remote: remote)

        XCTAssertEqual(projectID, "project-2")
        XCTAssertEqual(connection.requests.map(\.method), ["project.lookup", "project.add"])
        XCTAssertEqual(connection.requests.last?.params?["path"] as? String, "/home/wsl/dev/anomalyco/threadmill")
    }

    func testEnsureRepoOnRemoteClonesAndRegistersMissingRepository() async throws {
        let remote = makeRemote()
        let repo = makeRepo()
        let connection = MockDaemonConnection(state: .connected)
        let pool = MockRemoteConnectionPool()
        pool.connections[remote.id] = connection

        connection.requestHandler = { method, _, _ in
            switch method {
            case "project.lookup":
                return [
                    "exists": false,
                    "is_git_repo": false,
                    "project_id": NSNull(),
                ]
            case "project.clone":
                return ["id": "project-3"]
            default:
                throw TestError.missingStub
            }
        }

        let service = ProvisioningService(connectionPool: pool)
        let projectID = try await service.ensureRepoOnRemote(repo: repo, remote: remote)

        XCTAssertEqual(projectID, "project-3")
        XCTAssertEqual(connection.requests.map(\.method), ["project.lookup", "project.clone"])
        XCTAssertEqual(connection.requests.last?.params?["url"] as? String, repo.cloneURL)
        XCTAssertEqual(connection.requests.last?.params?["path"] as? String, "/home/wsl/dev/anomalyco/threadmill")

    }

    func testEnsureRepoOnRemoteThrowsWhenPathExistsButIsNotGitRepo() async {
        let remote = makeRemote()
        let repo = makeRepo()
        let connection = MockDaemonConnection(state: .connected)
        let pool = MockRemoteConnectionPool()
        pool.connections[remote.id] = connection

        connection.requestHandler = { method, _, _ in
            switch method {
            case "project.lookup":
                return [
                    "exists": true,
                    "is_git_repo": false,
                    "project_id": NSNull(),
                ]
            default:
                throw TestError.missingStub
            }
        }

        let service = ProvisioningService(connectionPool: pool)

        do {
            _ = try await service.ensureRepoOnRemote(repo: repo, remote: remote)
            XCTFail("Expected pathExistsButIsNotGitRepo error")
        } catch {
            guard case let ProvisioningError.pathExistsButIsNotGitRepo(path) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, "/home/wsl/dev/anomalyco/threadmill")
        }
    }

    func testEnsureRepoOnRemoteUsesOwnerQualifiedPathFromRootDirectory() async throws {
        let remote = Remote(
            id: "remote-1",
            name: "beast",
            host: "beast",
            daemonPort: 19990,
            useSSHTunnel: true,
            cloneRoot: "/"
        )
        let repo = makeRepo()
        let connection = MockDaemonConnection(state: .connected)
        let pool = MockRemoteConnectionPool()
        pool.connections[remote.id] = connection

        connection.requestHandler = { method, _, _ in
            switch method {
            case "project.lookup":
                return [
                    "exists": false,
                    "is_git_repo": false,
                    "project_id": NSNull(),
                ]
            case "project.clone":
                return ["id": "project-4"]
            default:
                throw TestError.missingStub
            }
        }

        let service = ProvisioningService(connectionPool: pool)
        _ = try await service.ensureRepoOnRemote(repo: repo, remote: remote)

        XCTAssertEqual(connection.requests.first?.params?["path"] as? String, "/anomalyco/threadmill")
    }

    private func makeRemote() -> Remote {
        Remote(
            id: "remote-1",
            name: "beast",
            host: "beast",
            daemonPort: 19990,
            useSSHTunnel: true,
            cloneRoot: "/home/wsl/dev"
        )
    }

    private func makeRepo() -> Repo {
        Repo(
            id: "repo-1",
            owner: "anomalyco",
            name: "threadmill",
            fullName: "anomalyco/threadmill",
            cloneURL: "git@github.com:anomalyco/threadmill.git",
            defaultBranch: "main",
            isPrivate: true,
            cachedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
