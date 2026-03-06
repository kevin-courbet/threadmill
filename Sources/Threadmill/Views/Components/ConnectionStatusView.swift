import SwiftUI

struct ConnectionStatusView: View {
    @Environment(AppState.self) private var appState
    let status: ConnectionStatus

    private var color: Color {
        switch status {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected:
            return .red
        }
    }

    private var text: String {
        switch status {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .reconnecting:
            return "Connecting..."
        case .disconnected:
            return "Disconnected"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                }
                .help(text)

            if let stats = appState.systemStats, case .connected = status {
                HStack(spacing: 12) {
                    Label(String(format: "%.2f", stats.loadAvg1m), systemImage: "cpu")
                        .help("Load Average (1m)")
                        .foregroundColor(stats.loadAvg1m > 4.0 ? .red : .secondary)

                    Label("\(stats.memoryUsedMb / 1024)GB / \(stats.memoryTotalMb / 1024)GB", systemImage: "memorychip")
                        .help("Memory Usage")
                        .foregroundColor(Double(stats.memoryUsedMb) / Double(stats.memoryTotalMb) > 0.8 ? .orange : .secondary)

                    if stats.opencodeInstances > 0 {
                        Label("\(stats.opencodeInstances)", systemImage: "bolt.fill")
                            .help("Opencode Instances")
                    }

                    Button(action: { Task { await appState.cleanupSystem() } }) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Cleanup Resources")
                    .foregroundColor(.secondary)
                }
                .font(.caption)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("connection.status")
        .accessibilityLabel("Connection")
        .accessibilityValue(status.label)
    }
}
