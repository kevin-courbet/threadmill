import Foundation

enum TerminalMultiplexerError: LocalizedError {
    case connectionUnavailable(threadID: String)

    var errorDescription: String? {
        switch self {
        case let .connectionUnavailable(threadID):
            "Connection unavailable for thread: \(threadID)."
        }
    }
}

@MainActor
final class TerminalMultiplexer: TerminalMultiplexing {
    private struct AttachmentKey: Hashable {
        let threadID: String
        let sessionID: String
    }

    private var endpointsByChannel: [UInt16: RelayEndpoint] = [:]
    private var endpointsByAttachment: [AttachmentKey: RelayEndpoint] = [:]

    // Buffer for binary frames that arrive before endpoint registration
    // (e.g. scrollback replay sent before terminal.attach RPC response)
    private var preRegistrationBuffer: [UInt16: [Data]] = [:]
    private let maxBufferedFramesPerChannel = 100

    private let connectionResolver: @MainActor (String) -> (any ConnectionManaging)?
    private let surfaceHost: any SurfaceHosting

    init(connectionManager: any ConnectionManaging, surfaceHost: any SurfaceHosting) {
        connectionResolver = { _ in connectionManager }
        self.surfaceHost = surfaceHost
    }

    init(
        connectionResolver: @escaping @MainActor (String) -> (any ConnectionManaging)?,
        surfaceHost: any SurfaceHosting
    ) {
        self.connectionResolver = connectionResolver
        self.surfaceHost = surfaceHost
    }

    func endpoint(threadID: String, sessionID: String) -> RelayEndpoint? {
        endpointsByAttachment[AttachmentKey(threadID: threadID, sessionID: sessionID)]
    }

    func attach(threadID: String, sessionID: String, preset: String) async throws -> RelayEndpoint {
        let key = AttachmentKey(threadID: threadID, sessionID: sessionID)
        if let existing = endpointsByAttachment[key] {
            if existing.channelID == 0 {
                let connectionManager = try connectionManager(for: threadID)
                try await attachEndpoint(existing, connectionManager: connectionManager)
            }
            return existing
        }

        let connectionManager = try connectionManager(for: threadID)

        let endpoint = RelayEndpoint(
            channelID: 0,
            threadID: threadID,
            preset: preset,
            connectionManager: connectionManager,
            surfaceHost: surfaceHost
        )
        endpoint.start()
        endpointsByAttachment[key] = endpoint

        do {
            try await attachEndpoint(endpoint, connectionManager: connectionManager)
            return endpoint
        } catch {
            endpointsByAttachment.removeValue(forKey: key)
            endpoint.stop()
            throw error
        }
    }

    func detach(channelID: UInt16) {
        guard let endpoint = endpointsByChannel[channelID] else {
            return
        }
        detach(endpoint: endpoint, sendDetachRPC: true)
    }

    func detach(threadID: String, sessionID: String) {
        guard let endpoint = endpointsByAttachment[AttachmentKey(threadID: threadID, sessionID: sessionID)] else {
            return
        }
        detach(endpoint: endpoint, sendDetachRPC: true)
    }

    func detachAll() {
        let endpoints = Array(endpointsByAttachment.values)
        for endpoint in endpoints {
            detach(endpoint: endpoint, sendDetachRPC: true)
        }
    }

    func handleBinaryFrame(_ data: Data) {
        guard data.count >= 2 else {
            return
        }

        let channelID = (UInt16(data[0]) << 8) | UInt16(data[1])
        if let endpoint = endpointsByChannel[channelID] {
            endpoint.handleBinaryFrame(data)
        } else {
            // Buffer frames that arrive before endpoint registration
            // (spindle sends scrollback replay before the RPC response)
            var buffer = preRegistrationBuffer[channelID] ?? []
            if buffer.count < maxBufferedFramesPerChannel {
                buffer.append(data)
                preRegistrationBuffer[channelID] = buffer
            }
        }
    }

    func reattachAll() async {
        guard !endpointsByAttachment.isEmpty else {
            return
        }

        let endpoints = Array(endpointsByAttachment.values)
        endpointsByChannel.removeAll(keepingCapacity: true)
        for endpoint in endpoints {
            endpoint.setChannelID(0)
        }

        var remapped: [UInt16: RelayEndpoint] = [:]
        for endpoint in endpoints {
            do {
                let connectionManager = try connectionManager(for: endpoint.threadID)
                let channelID = try await requestAttachChannel(
                    threadID: endpoint.threadID,
                    preset: endpoint.preset,
                    connectionManager: connectionManager
                )
                endpoint.setChannelID(channelID)
                remapped[channelID] = endpoint
                flushPreRegistrationBuffer(channelID: channelID, to: endpoint)
                await endpoint.replayResizeIfAvailable()
            } catch {
                NSLog("threadmill-mux: reattach failed for %@/%@: %@", endpoint.threadID, endpoint.preset, "\(error)")
            }
        }

        endpointsByChannel = remapped
    }

    private func attachEndpoint(_ endpoint: RelayEndpoint, connectionManager: any ConnectionManaging) async throws {
        let channelID = try await requestAttachChannel(
            threadID: endpoint.threadID,
            preset: endpoint.preset,
            connectionManager: connectionManager
        )

        if endpoint.channelID > 0 {
            endpointsByChannel.removeValue(forKey: endpoint.channelID)
        }

        if let existing = endpointsByChannel[channelID], existing !== endpoint {
            existing.setChannelID(0)
            endpointsByChannel.removeValue(forKey: channelID)
        }

        endpoint.setChannelID(channelID)
        endpointsByChannel[channelID] = endpoint
        flushPreRegistrationBuffer(channelID: channelID, to: endpoint)
        await endpoint.replayResizeIfAvailable()
    }

    private func flushPreRegistrationBuffer(channelID: UInt16, to endpoint: RelayEndpoint) {
        guard let frames = preRegistrationBuffer.removeValue(forKey: channelID) else {
            return
        }
        for frame in frames {
            endpoint.handleBinaryFrame(frame)
        }
    }

    private func detach(endpoint: RelayEndpoint, sendDetachRPC: Bool) {
        let threadID = endpoint.threadID
        let preset = endpoint.preset
        let channelID = endpoint.channelID
        if let attachmentKey = endpointsByAttachment.first(where: { $0.value === endpoint })?.key {
            endpointsByAttachment.removeValue(forKey: attachmentKey)
        }
        if endpoint.channelID > 0 {
            endpointsByChannel.removeValue(forKey: endpoint.channelID)
        }
        endpoint.stop()

        guard sendDetachRPC else {
            return
        }

        Task {
            guard let connectionManager = connectionResolver(threadID) else {
                NSLog(
                    "threadmill-mux: detach RPC skipped, no connection thread_id=%@ preset=%@ channel=%hu",
                    threadID,
                    preset,
                    channelID
                )
                return
            }
            do {
                _ = try await connectionManager.request(
                    method: "terminal.detach",
                    params: [
                        "thread_id": threadID,
                        "preset": preset,
                    ],
                    timeout: 5
                )
            } catch {
                NSLog(
                    "threadmill-mux: detach RPC failed thread_id=%@ preset=%@ channel=%hu error=%@",
                    threadID,
                    preset,
                    channelID,
                    "\(error)"
                )
            }
        }
    }

    private func connectionManager(for threadID: String) throws -> any ConnectionManaging {
        guard let connectionManager = connectionResolver(threadID) else {
            throw TerminalMultiplexerError.connectionUnavailable(threadID: threadID)
        }
        return connectionManager
    }

    private func requestAttachChannel(
        threadID: String,
        preset: String,
        connectionManager: any ConnectionManaging
    ) async throws -> UInt16 {
        let result = try await connectionManager.request(
            method: "terminal.attach",
            params: [
                "thread_id": threadID,
                "preset": preset,
            ],
            timeout: 10
        )

        guard let channelID = parseChannelID(from: result), channelID > 0 else {
            throw NSError(
                domain: "Threadmill",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "terminal.attach returned invalid channel_id"]
            )
        }

        return channelID
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
