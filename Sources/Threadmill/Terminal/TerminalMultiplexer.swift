import Foundation

@MainActor
final class TerminalMultiplexer {
    private(set) var endpoints: [UInt16: RelayEndpoint] = [:]

    private let connectionManager: ConnectionManager
    private let ghosttyManager: GhosttyManager

    init(connectionManager: ConnectionManager, ghosttyManager: GhosttyManager) {
        self.connectionManager = connectionManager
        self.ghosttyManager = ghosttyManager
    }

    func attach(threadID: String, preset: String) async throws -> RelayEndpoint {
        let result = try await connectionManager.request(
            method: "terminal.attach",
            params: [
                "thread_id": threadID,
                "preset": preset,
            ],
            timeout: 10
        )

        guard let channelID = parseChannelID(from: result), channelID > 0 else {
            throw NSError(domain: "Threadmill", code: -1, userInfo: [NSLocalizedDescriptionKey: "terminal.attach returned invalid channel_id"])
        }

        if let existing = endpoints[channelID] {
            existing.stop()
            endpoints.removeValue(forKey: channelID)
        }

        let endpoint = RelayEndpoint(
            channelID: channelID,
            threadID: threadID,
            preset: preset,
            connectionManager: connectionManager,
            ghosttyManager: ghosttyManager
        )
        endpoint.start()
        endpoints[channelID] = endpoint
        return endpoint
    }

    func detach(channelID: UInt16) {
        guard let endpoint = endpoints.removeValue(forKey: channelID) else {
            return
        }

        endpoint.stop()

        Task {
            _ = try? await connectionManager.request(
                method: "terminal.detach",
                params: [
                    "thread_id": endpoint.threadID,
                    "preset": endpoint.preset,
                ],
                timeout: 5
            )
        }
    }

    func handleBinaryFrame(_ data: Data) {
        guard data.count >= 2 else {
            return
        }
        let channel = (UInt16(data[0]) << 8) | UInt16(data[1])
        endpoints[channel]?.handleBinaryFrame(data)
    }

    func detachAll() {
        for channel in endpoints.keys {
            detach(channelID: channel)
        }
    }

    private func parseChannelID(from result: Any) -> UInt16? {
        if let intValue = result as? Int {
            guard intValue > 0, intValue <= Int(UInt16.max) else {
                return nil
            }
            return UInt16(intValue)
        }
        if let dict = result as? [String: Any] {
            if let value = dict["channel_id"] as? Int {
                guard value > 0, value <= Int(UInt16.max) else {
                    return nil
                }
                return UInt16(value)
            }
            if let value = dict["channel_id"] as? String,
               let parsed = UInt16(value),
               parsed > 0 {
                return parsed
            }
        }
        return nil
    }
}
