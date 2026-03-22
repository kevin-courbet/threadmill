import XCTest
@testable import Threadmill

@MainActor
final class RemoteConnectionPoolTests: XCTestCase {
    func testInitCreatesConnectionsForAllRemotes() {
        let remote = makeRemote(id: "remote-1")
        var factoryCalls = 0

        let pool = RemoteConnectionPool(remotes: [remote], connectionFactory: { _ in
            factoryCalls += 1
            return MockDaemonConnection(state: .disconnected)
        })

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertNil(pool.connection(for: "missing"))
        XCTAssertEqual(factoryCalls, 1)

        _ = pool.connection(for: remote.id)
        XCTAssertEqual(factoryCalls, 1)
    }

    func testConnectionForSameRemoteReturnsSameInstance() {
        let remote = makeRemote(id: "remote-1")

        let pool = RemoteConnectionPool(remotes: [remote], connectionFactory: { _ in
            MockDaemonConnection(state: .disconnected)
        })

        let first = pool.connection(for: remote.id)
        let second = pool.connection(for: remote.id)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertTrue((first as AnyObject?) === (second as AnyObject?))
    }

    func testEnsureConnectedDoesNotChangeActiveRemote() async throws {
        let remoteA = makeRemote(id: "remote-1")
        let remoteB = makeRemote(id: "remote-2")
        let connection = MockDaemonConnection(state: .disconnected)

        let pool = RemoteConnectionPool(remotes: [remoteA, remoteB], activeRemoteId: remoteA.id, connectionFactory: { _ in
            connection
        })

        try await pool.ensureConnected(remoteId: remoteB.id)

        XCTAssertEqual(pool.activeRemoteId, remoteA.id)
        XCTAssertEqual(connection.startCallCount, 1)
    }

    func testEnsureConnectedSkipsStartWhenAlreadyStarted() async throws {
        let remote = makeRemote(id: "remote-1")
        let connection = MockDaemonConnection(state: .connected)

        let pool = RemoteConnectionPool(remotes: [remote], connectionFactory: { _ in
            connection
        })

        try await pool.ensureConnected(remoteId: remote.id)

        XCTAssertEqual(connection.startCallCount, 0)
    }

    func testActivateSetsActiveRemoteId() throws {
        let remote = makeRemote(id: "remote-1")
        let pool = RemoteConnectionPool(remotes: [remote], connectionFactory: { _ in
            MockDaemonConnection(state: .disconnected)
        })

        try pool.activate(remoteId: remote.id)

        XCTAssertEqual(pool.activeRemoteId, remote.id)
    }

    func testAddUpdateAndRemoveRemoteManageConnectionLifecycle() {
        let remoteA = makeRemote(id: "remote-a")
        let remoteB = makeRemote(id: "remote-b")
        let remoteBUpdated = Remote(
            id: remoteB.id,
            name: remoteB.name,
            host: "beta-updated",
            daemonPort: remoteB.daemonPort + 1,
            useSSHTunnel: remoteB.useSSHTunnel,
            cloneRoot: remoteB.cloneRoot
        )

        var createdConnections: [MockDaemonConnection] = []
        let pool = RemoteConnectionPool(remotes: [remoteA], connectionFactory: { _ in
            let connection = MockDaemonConnection(state: .connected)
            createdConnections.append(connection)
            return connection
        })

        XCTAssertNil(pool.connection(for: remoteB.id))

        pool.addRemote(remoteB)
        let initialRemoteBConnection = pool.connection(for: remoteB.id)
        XCTAssertNotNil(initialRemoteBConnection)
        XCTAssertEqual(createdConnections.count, 2)

        pool.updateRemote(remoteBUpdated)
        let updatedRemoteBConnection = pool.connection(for: remoteB.id)
        XCTAssertNotNil(updatedRemoteBConnection)
        XCTAssertEqual(createdConnections.count, 3)
        XCTAssertFalse((initialRemoteBConnection as AnyObject?) === (updatedRemoteBConnection as AnyObject?))
        XCTAssertEqual(createdConnections[1].stopCallCount, 1)
        XCTAssertEqual(createdConnections[2].startCallCount, 1)

        pool.removeRemote(id: remoteB.id)
        XCTAssertNil(pool.connection(for: remoteB.id))
        XCTAssertEqual(createdConnections[2].stopCallCount, 1)
    }

    func testConnectionCreatedCallbackRunsForInitAndReplacements() {
        let remoteA = makeRemote(id: "remote-a")
        let remoteB = makeRemote(id: "remote-b")
        let remoteBUpdated = Remote(
            id: remoteB.id,
            name: remoteB.name,
            host: "beta-updated",
            daemonPort: remoteB.daemonPort,
            useSSHTunnel: remoteB.useSSHTunnel,
            cloneRoot: remoteB.cloneRoot
        )

        var callbackCount = 0
        let pool = RemoteConnectionPool(
            remotes: [remoteA],
            onConnectionCreated: { _ in callbackCount += 1 },
            connectionFactory: { _ in MockDaemonConnection(state: .disconnected) },
        )

        XCTAssertNotNil(pool.connection(for: remoteA.id))
        XCTAssertEqual(callbackCount, 1)

        pool.addRemote(remoteB)
        XCTAssertEqual(callbackCount, 2)

        pool.updateRemote(remoteBUpdated)
        XCTAssertEqual(callbackCount, 3)
    }

    private func makeRemote(id: String) -> Remote {
        Remote(
            id: id,
            name: "beast",
            host: "beast",
            daemonPort: 19990,
            useSSHTunnel: true,
            cloneRoot: "/home/wsl/dev"
        )
    }
}
