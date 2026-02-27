import Darwin
import Foundation

enum SSHTunnelError: LocalizedError {
    case failedToStart(host: String)

    var errorDescription: String? {
        switch self {
        case let .failedToStart(host):
            "SSH tunnel failed to start for host \(host)."
        }
    }
}

@MainActor
final class SSHTunnelManager: ObservableObject, TunnelManaging {
    @Published private(set) var isRunning = false

    let host: String
    let localPort: Int
    let remotePort: Int

    var onExit: ((Int32) -> Void)?

    private var process: Process?

    private let opencodePort = 4101

    init(host: String, localPort: Int, remotePort: Int) {
        self.host = host
        self.localPort = localPort
        self.remotePort = remotePort
    }

    func start() async throws {
        if isRunning {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "\(localPort):127.0.0.1:\(remotePort)",
        ]
        if localPort != opencodePort {
            arguments += ["-L", "\(opencodePort):127.0.0.1:\(opencodePort)"]
        }
        arguments.append(host)
        process.arguments = arguments

        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.isRunning = false
                self.process = nil
                self.onExit?(process.terminationStatus)
            }
        }

        try process.run()
        self.process = process
        self.isRunning = true

        // Wait for the tunnel to be ready (port accepting connections).
        // With SSH ControlMaster, the process may exit immediately with
        // code 0 after the master sets up forwarding — that's success.
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms
            if isPortOpen(localPort) { return }
            if !process.isRunning {
                // Process exited — check if port is open (ControlMaster case)
                if isPortOpen(localPort) { return }
                self.isRunning = false
                self.process = nil
                throw SSHTunnelError.failedToStart(host: host)
            }
        }
        // 10s timeout — tunnel never came up
        process.terminate()
        self.isRunning = false
        self.process = nil
        throw SSHTunnelError.failedToStart(host: host)
    }

    private func isPortOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    func stop() {
        guard let process else {
            isRunning = false
            return
        }

        if process.isRunning {
            process.terminate()
        }

        self.process = nil
        self.isRunning = false
    }

    func restart() async throws {
        stop()
        try await start()
    }
}
