import Foundation
import GhosttyKit
import XCTest
@testable import Threadmill

enum TestError: Error {
    case missingStub
    case forcedFailure
}

struct RecordedRequest {
    let method: String
    let params: [String: Any]?
}

@MainActor
final class MockDaemonConnection: ConnectionManaging {
    var state: ConnectionStatus
    var startCallCount = 0
    var stopCallCount = 0
    var requests: [RecordedRequest] = []
    var sentBinaryFrames: [Data] = []
    var requestHandler: ((String, [String: Any]?, TimeInterval) throws -> Any)?

    init(state: ConnectionStatus = .disconnected) {
        self.state = state
    }

    func start() {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func request(method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> Any {
        requests.append(RecordedRequest(method: method, params: params))
        if let requestHandler {
            return try requestHandler(method, params, timeout)
        }
        throw TestError.missingStub
    }

    func sendBinaryFrame(_ data: Data) async throws {
        sentBinaryFrames.append(data)
    }
}

@MainActor
final class MockSurfaceHost: SurfaceHosting {
    func createSurface(in _: GhosttyNSView, socketPath _: String) -> ghostty_surface_t? {
        nil
    }

    func freeSurface(_: ghostty_surface_t?) {}
}

@MainActor
final class MockSyncService: SyncServicing {
    var syncCount = 0
    var syncHandler: (() async -> Void)?

    func syncFromDaemon() async {
        syncCount += 1
        await syncHandler?()
    }
}

@MainActor
final class MockDatabaseManager: DatabaseManaging {
    var projects: [Project] = []
    var threads: [ThreadModel] = []
    var updateStatusResult = true
    var updatedStatuses: [(threadID: String, status: ThreadStatus)] = []

    func allProjects() throws -> [Project] {
        projects
    }

    func allThreads() throws -> [ThreadModel] {
        threads
    }

    func replaceAllFromDaemon(projects: [Project], threads: [ThreadModel]) throws {
        self.projects = projects
        self.threads = threads
    }

    func updateThreadStatus(threadID: String, status: ThreadStatus) throws -> Bool {
        updatedStatuses.append((threadID, status))
        return updateStatusResult
    }
}

@MainActor
final class MockTerminalMultiplexer: TerminalMultiplexing {
    var detachedByThreadPreset: [(threadID: String, preset: String)] = []
    var detachedChannels: [UInt16] = []
    var attachCallCount = 0
    var attachHandler: ((String, String) async throws -> RelayEndpoint)?

    func endpoint(threadID _: String, preset _: String) -> RelayEndpoint? {
        nil
    }

    func attach(threadID: String, preset: String) async throws -> RelayEndpoint {
        attachCallCount += 1
        if let attachHandler {
            return try await attachHandler(threadID, preset)
        }
        throw TestError.missingStub
    }

    func detach(channelID: UInt16) {
        detachedChannels.append(channelID)
    }

    func detach(threadID: String, preset: String) {
        detachedByThreadPreset.append((threadID, preset))
    }

    func detachAll() {}

    func handleBinaryFrame(_: Data) {}

    func reattachAll() async {}
}

@MainActor
final class MockTunnelManager: TunnelManaging {
    var onExit: ((Int32) -> Void)?
    var startCallCount = 0
    var stopCallCount = 0
    var startResults: [Result<Void, Error>] = []

    func enqueueStartResult(_ result: Result<Void, Error>) {
        startResults.append(result)
    }

    func start() async throws {
        startCallCount += 1
        if !startResults.isEmpty {
            let next = startResults.removeFirst()
            switch next {
            case .success:
                return
            case let .failure(error):
                throw error
            }
        }
    }

    func stop() {
        stopCallCount += 1
    }
}

@MainActor
final class MockWebSocketClient: WebSocketManaging {
    var onEvent: ((String, [String: Any]?) -> Void)?
    var onBinaryMessage: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    var connectURLs: [URL] = []
    var disconnectCallCount = 0
    var sentRequests: [RecordedRequest] = []
    var sentBinaryFrames: [Data] = []

    var requestHandler: ((String, [String: Any]?, TimeInterval) throws -> Any)?

    func connect(to url: URL) {
        connectURLs.append(url)
    }

    func disconnect() {
        disconnectCallCount += 1
    }

    func sendRequest(method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> Any {
        sentRequests.append(RecordedRequest(method: method, params: params))
        if let requestHandler {
            return try requestHandler(method, params, timeout)
        }
        throw TestError.missingStub
    }

    func sendBinaryFrame(_ data: Data) async throws {
        sentBinaryFrames.append(data)
    }

    func emitEvent(method: String, params: [String: Any]?) {
        onEvent?(method, params)
    }

    func emitBinaryMessage(_ data: Data) {
        onBinaryMessage?(data)
    }

    func emitDisconnect(_ error: Error?) {
        onDisconnect?(error)
    }
}

@MainActor
func waitForCondition(timeout: TimeInterval = 1.0, pollNanoseconds: UInt64 = 10_000_000, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
    return condition()
}

func makeFrame(channelID: UInt16, payload: [UInt8]) -> Data {
    var frame = Data([UInt8(channelID >> 8), UInt8(channelID & 0xFF)])
    frame.append(contentsOf: payload)
    return frame
}
