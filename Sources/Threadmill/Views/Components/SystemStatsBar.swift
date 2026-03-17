import SwiftUI

struct SystemStatsBar: View {
    @Environment(AppState.self) private var appState
    let status: ConnectionStatus

    var body: some View {
        Group {
            if let stats = appState.systemStats, case .connected = status {
                HStack(spacing: 12) {
                    statChip(systemImage: "cpu", text: String(format: "%.2f", stats.loadAvg1m))
                        .help("Load Average (1m)")
                        .foregroundColor(stats.loadAvg1m > 4.0 ? .red : .secondary)

                    statChip(systemImage: "memorychip", text: "\(stats.memoryUsedMb / 1024)GB/\(stats.memoryTotalMb / 1024)GB")
                        .help("Memory Usage")
                        .foregroundColor(Double(stats.memoryUsedMb) / Double(stats.memoryTotalMb) > 0.8 ? .orange : .secondary)

                    if stats.opencodeInstances > 0 {
                        statChip(systemImage: "bolt.fill", text: "\(stats.opencodeInstances)")
                            .help("Opencode Instances")
                    }
                }
                .font(.caption)
                .padding(.leading, 12)
                .padding(.trailing, 10)
            }
        }
    }

    private func statChip(systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .lineLimit(1)
    }
}
