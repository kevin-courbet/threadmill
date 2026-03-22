import XCTest

final class ProjectIntegrationTests: IntegrationTestCase {
    func testAddProjectAndVerifyInList() async throws {
        let conn = try await makeConnection()
        defer { conn.disconnect() }

        let addResult = try await conn.rpc("project.add", params: ["path": Self.fixtureRepoPath])
        let addedProject = try XCTUnwrap(addResult as? [String: Any])
        XCTAssertNotNil(addedProject["id"] as? String)

        let projectsResult = try await conn.rpc("project.list", params: nil)
        let projects = try XCTUnwrap(projectsResult as? [[String: Any]])
        let fixtureProject = try XCTUnwrap(projects.first(where: { ($0["path"] as? String) == Self.fixtureRepoPath }))

        XCTAssertEqual(fixtureProject["name"] as? String, "threadmill-test-fixture")
        XCTAssertEqual(fixtureProject["path"] as? String, Self.fixtureRepoPath)

        let presets = (fixtureProject["presets"] as? [[String: Any]]) ?? []
        let presetNames = Set(presets.compactMap { $0["name"] as? String })
        XCTAssertTrue(presetNames.contains("dev-server"))
        XCTAssertTrue(presetNames.contains("terminal"))

        let agents = (fixtureProject["agents"] as? [[String: Any]]) ?? []
        let agentNames = Set(agents.compactMap { $0["name"] as? String })
        XCTAssertTrue(agentNames.contains("opencode"))
        XCTAssertTrue(agentNames.contains("claude"))
    }
}
