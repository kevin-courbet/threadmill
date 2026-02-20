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
final class SSHTunnelManager: ObservableObject {
    @Published private(set) var isRunning = false

    let host: String
    let localPort: Int
    let remotePort: Int

    var onExit: ((Int32) -> Void)?

    private var process: Process?

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
        process.arguments = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "\(localPort):127.0.0.1:\(remotePort)",
            host
        ]

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

        try await Task.sleep(nanoseconds: 300_000_000)
        if !process.isRunning {
            self.isRunning = false
            self.process = nil
            throw SSHTunnelError.failedToStart(host: host)
        }
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
