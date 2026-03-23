import XCTest

final class PresetIntegrationTests: IntegrationTestCase {
    func testStartDevServerPreset() async throws {
        let conn = try await makeConnection()
        defer { conn.disconnect() }

        let threadID = try await createThread(conn: conn)

        addTeardownBlock {
            _ = try? await conn.rpc("preset.stop", params: ["thread_id": threadID, "preset": "dev-server"], timeout: 10)
        }

        _ = try await conn.rpc(
            "preset.start",
            params: [
                "thread_id": threadID,
                "preset": "dev-server",
            ],
            timeout: 20
        )

        let event = try await conn.waitForEvent("preset.process_event", timeout: 10)
        XCTAssertEqual(event["thread_id"] as? String, threadID)
        XCTAssertEqual(event["preset"] as? String, "dev-server")
        XCTAssertEqual(event["event"] as? String, "started")
    }
}
