import XCTest

final class ThreadIntegrationTests: IntegrationTestCase {
    func testCreateThreadCreatesWorktreeOnBeast() async throws {
        let conn = try await makeConnection()
        defer { conn.disconnect() }

        let projectID = try await ensureProjectID(conn: conn)

        let threadName = uniqueThreadName()
        let result = try await conn.rpc(
            "thread.create",
            params: [
                "project_id": projectID,
                "name": threadName,
                "source_type": "new_feature",
            ],
            timeout: 30
        )

        let createdThread = try XCTUnwrap(result as? [String: Any])
        let threadID = try XCTUnwrap(createdThread["id"] as? String)
        createdThreadIDs.append(threadID)

        try await waitForThreadActive(conn: conn, threadID: threadID)

        let threadsResult = try await conn.rpc("thread.list", params: nil)
        let threads = try XCTUnwrap(threadsResult as? [[String: Any]])
        let listedThread = try XCTUnwrap(threads.first(where: { ($0["id"] as? String) == threadID }))
        XCTAssertEqual(listedThread["status"] as? String, "active")

        let worktreePath = try XCTUnwrap(listedThread["worktree_path"] as? String)
        let sshStatus = try runSSH("test -d \"\(worktreePath)\"")
        XCTAssertEqual(sshStatus, 0)
    }
}
