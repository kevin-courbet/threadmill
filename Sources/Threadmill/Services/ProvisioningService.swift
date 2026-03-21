import Foundation

enum ProvisioningError: LocalizedError {
    case connectionUnavailable(remoteID: String)
    case invalidLookupResponse
    case invalidProjectResponse(method: String)
    case pathExistsButIsNotGitRepo(path: String)

    var errorDescription: String? {
        switch self {
        case let .connectionUnavailable(remoteID):
            return "Connection unavailable for remote: \(remoteID)."
        case .invalidLookupResponse:
            return "Invalid response for project.lookup."
        case let .invalidProjectResponse(method):
            return "Invalid response for \(method)."
        case let .pathExistsButIsNotGitRepo(path):
            return "Path exists but is not a git repository: \(path)."
        }
    }
}

@MainActor
protocol Provisioning: AnyObject {
    func ensureRepoOnRemote(repo: Repo, remote: Remote) async throws -> String
    func lookupProject(path: String, on remoteId: String) async throws -> (exists: Bool, isGitRepo: Bool, projectId: String?)
}

@MainActor
final class ProvisioningService: Provisioning {
    private let connectionPool: any RemoteConnectionPooling

    init(connectionPool: any RemoteConnectionPooling) {
        self.connectionPool = connectionPool
    }

    func ensureRepoOnRemote(repo: Repo, remote: Remote) async throws -> String {
        let expectedPath = Remote.joinedRemotePath(root: remote.cloneRoot, owner: repo.owner, repoName: repo.name)
        let lookupResult = try await lookupProject(path: expectedPath, on: remote.id)

        if let existingProjectID = lookupResult.projectId {
            return existingProjectID
        }

        let connection = try connection(for: remote.id)

        if lookupResult.exists {
            guard lookupResult.isGitRepo else {
                throw ProvisioningError.pathExistsButIsNotGitRepo(path: expectedPath)
            }
            return try await registerProject(path: expectedPath, using: connection)
        }

        return try await cloneAndRegisterProject(url: repo.cloneURL, path: expectedPath, using: connection)
    }

    func lookupProject(path: String, on remoteId: String) async throws -> (exists: Bool, isGitRepo: Bool, projectId: String?) {
        try await connectionPool.ensureConnected(remoteId: remoteId)
        let connection = try connection(for: remoteId)
        let result = try await connection.request(
            method: "project.lookup",
            params: ["path": path],
            timeout: 20
        )

        guard
            let payload = result as? [String: Any],
            let exists = payload["exists"] as? Bool,
            let isGitRepo = payload["is_git_repo"] as? Bool
        else {
            throw ProvisioningError.invalidLookupResponse
        }

        return (exists: exists, isGitRepo: isGitRepo, projectId: payload["project_id"] as? String)
    }

    private func registerProject(path: String, using connection: any ConnectionManaging) async throws -> String {
        let result = try await connection.request(
            method: "project.add",
            params: ["path": path],
            timeout: 30
        )
        return try projectID(from: result, method: "project.add")
    }

    private func cloneAndRegisterProject(url: String, path: String, using connection: any ConnectionManaging) async throws -> String {
        let result = try await connection.request(
            method: "project.clone",
            params: [
                "url": url,
                "path": path,
            ],
            timeout: 120
        )
        return try projectID(from: result, method: "project.clone")
    }

    private func connection(for remoteId: String) throws -> any ConnectionManaging {
        guard let connection = connectionPool.connection(for: remoteId) else {
            throw ProvisioningError.connectionUnavailable(remoteID: remoteId)
        }
        return connection
    }

    private func projectID(from payload: Any, method: String) throws -> String {
        guard
            let project = payload as? [String: Any],
            let projectID = project["id"] as? String,
            !projectID.isEmpty
        else {
            throw ProvisioningError.invalidProjectResponse(method: method)
        }
        return projectID
    }
}
