import SwiftUI

struct SystemStatsBar: View {
    @Environment(AppState.self) private var appState
    let status: ConnectionStatus
    @State private var isCleanupHovered = false

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

                    Button(action: { Task { await appState.cleanupSystem() } }) {
                        Image(systemName: "trash")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isCleanupHovered ? Color.white.opacity(0.08) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Cleanup Resources")
                    .foregroundColor(isCleanupHovered ? .primary : .secondary)
                    .onHover { isCleanupHovered = $0 }
                }
                .font(.caption)
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
