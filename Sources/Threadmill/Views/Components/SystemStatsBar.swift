import SwiftUI

struct SystemStatsBar: View {
    @Environment(AppState.self) private var appState
    let status: ConnectionStatus

    var body: some View {
        Group {
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
    }
}
