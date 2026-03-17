import Foundation
import XCTest

final class MultiRemoteIsolationSourceTests: XCTestCase {
    func testAppStateTracksDaemonRuntimeStatePerRemote() throws {
        let source = try loadSource(at: "Sources/Threadmill/App/AppState.swift")

        XCTAssertTrue(source.contains("latestDaemonStateVersionByRemoteID"))
        XCTAssertTrue(source.contains("stateDeltaResyncRequiredByRemoteID"))
        XCTAssertTrue(source.contains("presetOutputByRemoteSession"))
        XCTAssertTrue(source.contains("handleDaemonEvent(method: String, params: [String: Any]?, remoteID: String)"))
        XCTAssertTrue(source.contains("applyDaemonSnapshotStateVersion(_ stateVersion: Int, remoteID: String)"))
    }

    func testAppDelegateRoutesConnectionCallbacksWithRemoteIdentity() throws {
        let source = try loadSource(at: "Sources/Threadmill/App/AppDelegate.swift")

        XCTAssertTrue(source.contains("configureConnectionHandlers(for connection: any ConnectionManaging, remoteID: String, appState: AppState)"))
        XCTAssertTrue(source.contains("self.configureConnectionHandlers(for: connection, remoteID: remote.id, appState: appState)"))
        XCTAssertTrue(source.contains("appState?.handleDaemonEvent(method: method, params: params, remoteID: remoteID)"))
    }

    private func loadSource(at relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: sourcePath, encoding: .utf8)
    }
}
