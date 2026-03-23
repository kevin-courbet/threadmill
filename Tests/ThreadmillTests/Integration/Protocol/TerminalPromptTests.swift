import XCTest

/// Regression test: new terminal should show the shell prompt without
/// requiring the user to press Enter. The prompt must arrive via
/// pipe-pane output after the initial capture_pane_visible replay.
final class TerminalPromptTests: IntegrationTestCase {
    func testNewTerminalShowsPromptWithoutEnterPress() async throws {
        let conn = try await makeConnection()
        defer { conn.disconnect() }

        let threadID = try await createThread(conn: conn)
        let attachResult = try await conn.rpc(
            "terminal.attach",
            params: [
                "thread_id": threadID,
                "preset": "terminal",
            ]
        )
        let attachPayload = try XCTUnwrap(attachResult as? [String: Any])
        let channelIDValue = try XCTUnwrap(attachPayload["channel_id"] as? Int)
        let channelID = UInt16(channelIDValue)

        // DO NOT send any input — no Enter, no keypress.
        // Collect all binary frames for 5 seconds.
        var allOutput = ""
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let frame: Data
            do {
                frame = try await conn.waitForBinaryFrame(channelID: channelID, timeout: 1.0)
            } catch {
                continue
            }
            let payload = Data(frame.dropFirst(2))
            allOutput.append(String(decoding: payload, as: UTF8.self))
        }

        // The output must contain the shell prompt — not just login messages.
        // Starship prompt contains "❯" or "via". A basic shell has "$" or "%".
        // We check for ANY of these prompt indicators.
        let hasPrompt = allOutput.contains("❯")
            || allOutput.contains("$")
            || allOutput.contains("%")
            || allOutput.contains("via")
            || allOutput.contains("at ")

        XCTAssertTrue(
            hasPrompt,
            "Terminal output should contain a prompt without pressing Enter.\nGot: \(allOutput.prefix(500))"
        )
    }
}
