import SwiftUI

struct TerminalTabView: View {
    let endpoint: RelayEndpoint?
    let isConnecting: Bool

    private var isMockTerminalEnabled: Bool {
        let value = ProcessInfo.processInfo.environment["THREADMILL_USE_MOCK_TERMINAL"]?.lowercased() ?? ""
        return value == "1" || value == "true" || value == "yes"
    }

    var body: some View {
        ZStack {
            if let endpoint {
                if isMockTerminalEnabled {
                    Text("Mock terminal: \(endpoint.preset)")
                        .accessibilityIdentifier("terminal.mock.text")
                } else {
                    GhosttyTerminalView(endpoint: endpoint)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(isConnecting ? "Connecting..." : "Starting terminal...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("terminal.connecting")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.96))
        .accessibilityIdentifier("terminal.content")
        .accessibilityValue(endpoint?.preset ?? "detached")
    }
}
