import Foundation
import GhosttyKit
import os

@MainActor
final class RelayEndpoint {
    private(set) var channelID: UInt16
    let threadID: String
    let preset: String
    let sessionID: String
    let socketPath: String

    private let connectionManager: any ConnectionManaging
    private let surfaceHost: any SurfaceHosting

    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var listenSource: DispatchSourceRead?
    private var pendingFrames: [Data] = []
    private var pendingFrameBytes = 0
    private let maxPendingFrames = 1000
    private let maxPendingBytes = 1_000_000

    private weak var mountedView: GhosttyNSView?
    private var surface: ghostty_surface_t?

    /// Raw terminal output bytes stripped of ANSI escapes, for accessibility/testing.
    /// Capped at last 8KB to avoid unbounded growth.
    private var terminalTextBuffer = Data()
    private let terminalTextBufferMax = 8192

    var terminalText: String {
        // Strip ANSI escape sequences and return plain text
        let raw = String(decoding: terminalTextBuffer, as: UTF8.self)
        return raw.replacingOccurrences(
            of: "\\x1b\\[[0-9;]*[a-zA-Z]|\\x1b\\][^\u{07}]*\u{07}|\\x1b\\[\\?[0-9;]*[a-zA-Z]",
            with: "",
            options: .regularExpression
        )
    }
    private var desiredColumns: Int?
    private var desiredRows: Int?

    init(
        channelID: UInt16,
        threadID: String,
        preset: String,
        sessionID: String,
        connectionManager: any ConnectionManaging,
        surfaceHost: any SurfaceHosting
    ) {
        self.channelID = channelID
        self.threadID = threadID
        self.preset = preset
        self.sessionID = sessionID
        self.connectionManager = connectionManager
        self.surfaceHost = surfaceHost
        socketPath = "/tmp/threadmill-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).sock"
    }

    func start() {
        startListening()
    }

    func setChannelID(_ channelID: UInt16) {
        self.channelID = channelID
    }

    func mount(on view: GhosttyNSView) {
        if mountedView === view, surface != nil {
            return
        }

        if mountedView !== view {
            if let previousView = mountedView {
                unmount(from: previousView)
            }
            mountedView = view
            view.onSizeChanged = { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.syncTerminalSize()
                }
            }
        }

        guard surface == nil else { return }

        guard let createdSurface = surfaceHost.createSurface(in: view, socketPath: socketPath) else {
            Logger.relay.error("Failed to create ghostty surface for endpoint \(self.threadID)/\(self.preset)")
            return
        }
        surface = createdSurface
        if let ghosttySurfaceHost = surfaceHost as? GhosttySurfaceHost {
            ghosttySurfaceHost.register(surface: createdSurface, for: self)
        }

        Task {
            await syncTerminalSize()
        }
    }

    func unmount(from view: GhosttyNSView) {
        guard mountedView === view else { return }
        mountedView = nil
        view.onSizeChanged = nil
        view.surface = nil
        surfaceHost.freeSurface(surface)
        surface = nil
    }

    func relayChildExited(surface exitedSurface: ghostty_surface_t) {
        guard surface == exitedSurface else { return }
        channelID = 0
        Logger.relay.info("Relay exited for endpoint \(self.threadID)/\(self.preset)")
    }

    func surfaceClosed(_ closedSurface: ghostty_surface_t, processAlive: Bool) {
        guard surface == closedSurface else { return }
        channelID = 0
        surface = nil
        mountedView?.surface = nil
        Logger.relay.info("Surface closed for endpoint \(self.threadID)/\(self.preset) process_alive=\(processAlive)")
    }

    func stop() {
        if let source = readSource {
            readSource = nil
            source.cancel()
        } else if clientFD >= 0 {
            Darwin.close(clientFD)
            clientFD = -1
        }

        if let source = listenSource {
            listenSource = nil
            source.cancel()
        } else if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }

        unlink(socketPath)
        surfaceHost.freeSurface(surface)
        surface = nil
        mountedView?.onSizeChanged = nil
        mountedView?.surface = nil
        mountedView = nil
        pendingFrames.removeAll(keepingCapacity: false)
        pendingFrameBytes = 0
        channelID = 0
    }

    func handleBinaryFrame(_ frame: Data) {
        guard frame.count >= 2 else {
            return
        }

        let channel = (UInt16(frame[0]) << 8) | UInt16(frame[1])
        guard channel == channelID else {
            return
        }

        guard clientFD >= 0 else {
            Logger.relay.debug("BUFFERING \(frame.count - 2) bytes for \(self.threadID)/\(self.preset) (clientFD=-1, pending=\(self.pendingFrames.count))")
            // Accumulate for accessibility even while buffering — the surface
            // may query terminalText before the relay socket connects.
            let payload = frame.dropFirst(2)
            if !payload.isEmpty {
                terminalTextBuffer.append(contentsOf: payload)
                if terminalTextBuffer.count > terminalTextBufferMax {
                    terminalTextBuffer.removeFirst(terminalTextBuffer.count - terminalTextBufferMax)
                }
            }
            enqueuePendingFrame(frame)
            return
        }

        writeFrameToRelay(frame)
    }

    func desiredTerminalSize() -> (columns: Int, rows: Int)? {
        guard
            let desiredColumns,
            let desiredRows,
            desiredColumns > 0,
            desiredRows > 0
        else {
            return nil
        }
        return (desiredColumns, desiredRows)
    }

    func replayResizeIfAvailable() async {
        guard
            connectionManager.state.isConnected,
            channelID > 0,
            let size = desiredTerminalSize()
        else {
            return
        }

        do {
            _ = try await connectionManager.request(
                method: "terminal.resize",
                params: [
                    "thread_id": threadID,
                    "preset": preset,
                    "session_id": sessionID,
                    "cols": size.columns,
                    "rows": size.rows,
                ],
                timeout: 5
            )
        } catch {
            Logger.relay.error("Resize replay failed for \(self.threadID)/\(self.preset): \(error)")
        }
    }

    private func startListening() {
        unlink(socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            Logger.relay.error("socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { buf in
                _ = socketPath.withCString { strncpy(buf, $0, 103) }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Logger.relay.error("bind(\(self.socketPath)) failed: \(String(cString: strerror(errno)))")
            Darwin.close(listenFD)
            listenFD = -1
            return
        }

        guard listen(listenFD, 1) == 0 else {
            Logger.relay.error("listen() failed: \(String(cString: strerror(errno)))")
            Darwin.close(listenFD)
            listenFD = -1
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.listenFD, fd >= 0 {
                Darwin.close(fd)
            }
            self?.listenFD = -1
        }
        source.resume()
        listenSource = source
    }

    private func acceptClient() {
        if let source = readSource {
            readSource = nil
            source.cancel()
        } else if clientFD >= 0 {
            Darwin.close(clientFD)
            clientFD = -1
        }

        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else {
            return
        }
        clientFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readFromRelay(fd: fd)
        }
        source.setCancelHandler { [weak self] in
            Darwin.close(fd)
            if self?.clientFD == fd {
                self?.clientFD = -1
            }
        }
        source.resume()
        readSource = source

        flushPendingFrames()
    }

    private func readFromRelay(fd: Int32) {
        guard fd >= 0 else {
            return
        }

        var buf = [UInt8](repeating: 0, count: 16384)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else {
            readSource?.cancel()
            return
        }

        forwardRelayPayload(Data(buf[0 ..< n]))
    }

    private func forwardRelayPayload(_ payload: Data) {
        guard connectionManager.state.isConnected else {
            return
        }
        guard channelID > 0 else {
            return
        }

        var frame = Data(count: 2 + payload.count)
        frame[0] = UInt8(channelID >> 8)
        frame[1] = UInt8(channelID & 0xFF)
        frame.replaceSubrange(2 ..< (2 + payload.count), with: payload)

        let activeChannelID = channelID
        Task {
            do {
                try await connectionManager.sendBinaryFrame(frame)
            } catch {
                Logger.relay.error("Binary send failed thread_id=\(self.threadID) preset=\(self.preset) channel=\(activeChannelID): \(error)")
                Logger.relay.error("Forcing transport recovery thread_id=\(self.threadID) preset=\(self.preset) channel=\(activeChannelID)")
                connectionManager.stop()
                connectionManager.start()
            }
        }
    }

    func forwardRelayPayloadForTesting(_ payload: Data) {
        forwardRelayPayload(payload)
    }

    var bufferedFrameCount: Int {
        pendingFrames.count
    }

    func bufferedFrame(at index: Int) -> Data? {
        guard pendingFrames.indices.contains(index) else {
            return nil
        }
        return pendingFrames[index]
    }

    private func enqueuePendingFrame(_ frame: Data) {
        if frame.count > maxPendingBytes {
            Logger.relay.error("Dropping oversized frame (\(frame.count) bytes) for \(self.threadID)/\(self.preset)")
            return
        }

        while pendingFrames.count >= maxPendingFrames || (pendingFrameBytes + frame.count) > maxPendingBytes {
            guard !pendingFrames.isEmpty else {
                break
            }
            let dropped = pendingFrames.removeFirst()
            pendingFrameBytes -= dropped.count
        }
        pendingFrames.append(frame)
        pendingFrameBytes += frame.count
    }

    private func flushPendingFrames() {
        guard clientFD >= 0, !pendingFrames.isEmpty else {
            return
        }
        Logger.relay.debug("FLUSHING \(self.pendingFrames.count) pending frames (\(self.pendingFrameBytes) bytes) for \(self.threadID)/\(self.preset)")
        let frames = pendingFrames
        pendingFrames.removeAll(keepingCapacity: false)
        pendingFrameBytes = 0
        for frame in frames {
            writeFrameToRelay(frame)
        }
    }

    private func writeFrameToRelay(_ frame: Data) {
        let payload = frame.dropFirst(2)
        guard !payload.isEmpty else {
            return
        }

        // Accumulate for accessibility
        terminalTextBuffer.append(contentsOf: payload)
        if terminalTextBuffer.count > terminalTextBufferMax {
            terminalTextBuffer.removeFirst(terminalTextBuffer.count - terminalTextBufferMax)
        }

        payload.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress else {
                return
            }
            var remaining = payload.count
            var offset = 0
            while remaining > 0 {
                let written = write(clientFD, ptr.advanced(by: offset), remaining)
                if written <= 0 {
                    break
                }
                offset += written
                remaining -= written
            }
        }
    }

    private func syncTerminalSize() async {
        guard let surface else {
            return
        }

        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else {
            return
        }

        desiredColumns = Int(size.columns)
        desiredRows = Int(size.rows)

        guard connectionManager.state.isConnected, channelID > 0 else {
            return
        }

        do {
            _ = try await connectionManager.request(
                method: "terminal.resize",
                params: [
                    "thread_id": threadID,
                    "preset": preset,
                    "session_id": sessionID,
                    "cols": desiredColumns ?? Int(size.columns),
                    "rows": desiredRows ?? Int(size.rows),
                ],
                timeout: 5
            )
        } catch {
            Logger.relay.error("Resize failed for \(self.threadID)/\(self.preset): \(error)")
        }
    }
}
