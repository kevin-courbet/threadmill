import Foundation
import GhosttyKit

@MainActor
final class RelayEndpoint {
    private(set) var channelID: UInt16
    let threadID: String
    let preset: String
    let socketPath: String

    private let connectionManager: ConnectionManager
    private let surfaceHost: GhosttySurfaceHost

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
    private var desiredColumns: Int?
    private var desiredRows: Int?

    init(
        channelID: UInt16,
        threadID: String,
        preset: String,
        connectionManager: ConnectionManager,
        surfaceHost: GhosttySurfaceHost
    ) {
        self.channelID = channelID
        self.threadID = threadID
        self.preset = preset
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
        if mountedView !== view {
            mountedView?.surface = nil
            mountedView = view
            view.onSizeChanged = { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.syncTerminalSize()
                }
            }
        }

        if let existingSurface = surface {
            view.surface = existingSurface
            return
        }

        guard let createdSurface = surfaceHost.createSurface(in: view, socketPath: socketPath) else {
            NSLog("threadmill-relay: failed to create ghostty surface for endpoint %@/%@", threadID, preset)
            return
        }
        surface = createdSurface

        Task {
            await syncTerminalSize()
        }
    }

    func unmount(view: GhosttyNSView) {
        if mountedView === view {
            mountedView = nil
        }
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
                    "cols": size.columns,
                    "rows": size.rows,
                ],
                timeout: 5
            )
        } catch {
            NSLog("threadmill-relay: resize replay failed for %@/%@: %@", threadID, preset, "\(error)")
        }
    }

    private func startListening() {
        unlink(socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            NSLog("threadmill-relay: socket() failed: %s", String(cString: strerror(errno)))
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
            NSLog("threadmill-relay: bind(%@) failed: %s", socketPath, String(cString: strerror(errno)))
            Darwin.close(listenFD)
            listenFD = -1
            return
        }

        guard listen(listenFD, 1) == 0 else {
            NSLog("threadmill-relay: listen() failed: %s", String(cString: strerror(errno)))
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

        guard connectionManager.state.isConnected else {
            return
        }
        guard channelID > 0 else {
            return
        }

        var frame = Data(count: 2 + n)
        frame[0] = UInt8(channelID >> 8)
        frame[1] = UInt8(channelID & 0xFF)
        frame.replaceSubrange(2 ..< (2 + n), with: buf[0 ..< n])

        Task {
            try? await connectionManager.sendBinaryFrame(frame)
        }
    }

    private func enqueuePendingFrame(_ frame: Data) {
        if frame.count > maxPendingBytes {
            NSLog("threadmill-relay: dropping oversized frame (%d bytes) for %@/%@", frame.count, threadID, preset)
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
                    "cols": desiredColumns ?? Int(size.columns),
                    "rows": desiredRows ?? Int(size.rows),
                ],
                timeout: 5
            )
        } catch {
            NSLog("threadmill-relay: resize failed for %@/%@: %@", threadID, preset, "\(error)")
        }
    }
}
