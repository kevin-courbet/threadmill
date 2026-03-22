import XCTest
@testable import Threadmill

@MainActor
final class FileServiceTests: XCTestCase {
    func testListDirectoryDoesNotSendRPCBeforeConnectionIsReady() async {
        let connection = MockDaemonConnection(state: .connecting)
        let service = FileService(connectionManager: connection)

        do {
            _ = try await service.listDirectory(path: "/tmp/worktree")
            XCTFail("Expected file.list to fail before session handshake completes")
        } catch let error as FileServiceError {
            guard case .connectionNotReady = error else {
                return XCTFail("Unexpected FileServiceError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(connection.requests.isEmpty)
    }
}
