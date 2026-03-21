import Foundation

enum RemoteConnectionPoolError: LocalizedError {
    case unknownRemote(id: String)

    var errorDescription: String? {
        switch self {
        case let .unknownRemote(id):
            "Unknown remote id: \(id)."
        }
    }
}

@MainActor
protocol RemoteConnectionPooling: AnyObject {
    func connection(for remoteId: String) -> (any ConnectionManaging)?
    func addRemote(_ remote: Remote)
    func removeRemote(id: String)
    func updateRemote(_ remote: Remote)
    func activate(remoteId: String) throws
    func ensureConnected(remoteId: String) async throws
    func stopAll()
    var activeRemoteId: String? { get }
}

@MainActor
final class RemoteConnectionPool: RemoteConnectionPooling {
    private var remotesByID: [String: Remote]
    private var connections: [String: any ConnectionManaging] = [:]
    private let connectionFactory: @MainActor (Remote) -> any ConnectionManaging
    private let onConnectionCreated: @MainActor (any ConnectionManaging) -> Void

    private(set) var activeRemoteId: String?

    init(
        remotes: [Remote],
        activeRemoteId: String? = nil,
        onConnectionCreated: @escaping @MainActor (any ConnectionManaging) -> Void = { _ in },
        connectionFactory: @escaping @MainActor (Remote) -> any ConnectionManaging = { remote in
            ConnectionManager(config: ThreadmillConfig(remote: remote))
        }
    ) {
        self.remotesByID = Dictionary(uniqueKeysWithValues: remotes.map { ($0.id, $0) })
        if let activeRemoteId, self.remotesByID[activeRemoteId] != nil {
            self.activeRemoteId = activeRemoteId
        } else {
            self.activeRemoteId = remotes.first?.id
        }
        self.connectionFactory = connectionFactory
        self.onConnectionCreated = onConnectionCreated

        for remote in remotes {
            connections[remote.id] = createConnection(for: remote)
        }
    }

    convenience init(
        remotes: [Remote],
        activeRemoteId: String? = nil,
        connectionFactory: @escaping @MainActor (Remote) -> any ConnectionManaging
    ) {
        self.init(
            remotes: remotes,
            activeRemoteId: activeRemoteId,
            onConnectionCreated: { _ in },
            connectionFactory: connectionFactory
        )
    }

    func connection(for remoteId: String) -> (any ConnectionManaging)? {
        guard remotesByID[remoteId] != nil else {
            return nil
        }

        guard let remote = remotesByID[remoteId] else {
            return nil
        }

        if let existing = connections[remoteId] {
            return existing
        }

        let connection = createConnection(for: remote)
        connections[remoteId] = connection
        return connection
    }

    func addRemote(_ remote: Remote) {
        if remotesByID[remote.id] != nil {
            updateRemote(remote)
            return
        }

        remotesByID[remote.id] = remote
        connections[remote.id] = createConnection(for: remote)
    }

    func removeRemote(id: String) {
        remotesByID.removeValue(forKey: id)

        if let connection = connections.removeValue(forKey: id) {
            connection.stop()
        }

        if activeRemoteId == id {
            activeRemoteId = remotesByID.keys.sorted().first
        }
    }

    func updateRemote(_ remote: Remote) {
        guard let existingRemote = remotesByID[remote.id] else {
            addRemote(remote)
            return
        }

        remotesByID[remote.id] = remote

        guard didConnectionConfigChange(from: existingRemote, to: remote),
              let existingConnection = connections[remote.id]
        else {
            return
        }

        let shouldReconnect = existingConnection.state != .disconnected
        existingConnection.stop()

        let replacement = createConnection(for: remote)
        connections[remote.id] = replacement

        if shouldReconnect {
            replacement.start()
        }
    }

    func ensureConnected(remoteId: String) async throws {
        guard let connection = connection(for: remoteId) else {
            throw RemoteConnectionPoolError.unknownRemote(id: remoteId)
        }

        guard connection.state == .disconnected else {
            return
        }

        connection.start()
    }

    func activate(remoteId: String) throws {
        guard remotesByID[remoteId] != nil else {
            throw RemoteConnectionPoolError.unknownRemote(id: remoteId)
        }
        activeRemoteId = remoteId
    }

    func stopAll() {
        for connection in connections.values {
            connection.stop()
        }
        activeRemoteId = nil
    }

    private func createConnection(for remote: Remote) -> any ConnectionManaging {
        let connection = connectionFactory(remote)
        onConnectionCreated(connection)
        return connection
    }

    private func didConnectionConfigChange(from oldRemote: Remote, to newRemote: Remote) -> Bool {
        oldRemote.host != newRemote.host
            || oldRemote.daemonPort != newRemote.daemonPort
            || oldRemote.useSSHTunnel != newRemote.useSSHTunnel
    }
}
