import XCTest

final class TerminalIntegrationTests: IntegrationTestCase {
    func testAttachTerminalAndReceiveShellOutput() async throws {
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

        let marker = "integration-shell-\(UUID().uuidString.prefix(8))"
        let command = "echo \(marker)\n"
        let frame = makeFrame(channelID: channelID, payload: Array(command.utf8))
        try await conn.sendBinary(frame)

        let output = try await waitForTerminalOutput(conn: conn, channelID: channelID, contains: marker, timeout: 15)
        XCTAssertTrue(output.contains(marker))
    }

    /// First terminal attach must deliver the shell prompt without any user input.
    /// Reproduces the bug where the prompt only appeared after pressing Enter.
    func testFirstTerminalAttachDeliversPromptWithoutInput() async throws {
        let conn = try await makeConnection()
        defer { conn.disconnect() }

        let threadID = try await createThread(conn: conn)

        // Give the shell a moment to render its prompt in the tmux pane
        try await Task.sleep(nanoseconds: 500_000_000)

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

        // Collect all binary frames for this channel without sending any input.
        // The shell prompt (e.g. "%" or "$" or "❯") must arrive from the
        // scrollback replay.
        let deadline = Date().addingTimeInterval(5)
        var receivedData = Data()
        while Date() < deadline {
            do {
                let frame = try await conn.waitForBinaryFrame(channelID: channelID, timeout: 2.0)
                receivedData.append(contentsOf: frame.dropFirst(2))
            } catch {
                break
            }
        }

        let received = String(decoding: receivedData, as: UTF8.self)
        let trimmed = received.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmed.isEmpty, "Expected shell prompt on first attach without input, but received nothing. Full output: \(received)")

        // The replay must end with \r\n so the cursor lands below the prompt,
        // not on the prompt line itself.
        XCTAssertTrue(
            receivedData.suffix(2) == Data([0x0D, 0x0A]),
            "Scrollback replay must end with CR+LF for correct cursor positioning. Last bytes: \(Array(receivedData.suffix(20)))"
        )
    }
}
