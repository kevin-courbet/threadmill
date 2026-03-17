import XCTest
@testable import Threadmill

@MainActor
final class MockDaemonConnectionTests: XCTestCase {
    func testRequestRecordsSystemStatsMethod() async throws {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { _, _, _ in
            [String: Any]()
        }

        _ = try await connection.request(method: "system.stats", params: nil, timeout: 5)

        XCTAssertEqual(connection.requests.map(\.method), ["system.stats"])
    }
}
