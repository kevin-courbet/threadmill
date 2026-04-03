import ACPModel
import AppKit
import SwiftUI

struct ToolCallGroupView: View {
    let group: ToolCallGroup
    var childToolCalls: [String: [ToolCallTimelineItem]] = [:]

    @State private var isExpanded: Bool
    @State private var forceExpandAll = false

    init(group: ToolCallGroup, childToolCalls: [String: [ToolCallTimelineItem]] = [:]) {
        self.group = group
        self.childToolCalls = childToolCalls
        // Start expanded when created during streaming transition so the height
        // matches the individual tool calls being replaced — avoids scroll jump.
        _isExpanded = State(initialValue: group.isStreaming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: status dot + up-to-4 kind icons + "N tool calls" + chevron
            Button {
                withAnimation(.easeInOut(duration: ChatTokens.durNormal)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    statusDot
                    toolIcons

                    Text("\(group.toolCalls.count) tool calls")
                        .font(.system(size: ChatTokens.captionFontSize, weight: .semibold))
                        .foregroundStyle(ChatTokens.textPrimary)

                    if let duration = group.durationSeconds {
                        Text(Self.formatDuration(duration))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(ChatTokens.textFaint)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ChatTokens.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded body
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.displayItems) { displayItem in
                        switch displayItem {
                        case let .toolCall(item):
                            ToolCallView(
                                item: item,
                                childToolCalls: childToolCalls[item.id] ?? [],
                                forceExpanded: forceExpandAll,
                                isGrouped: true
                            )
                        case let .exploration(cluster):
                            explorationRow(cluster)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 4)
        .onAppear {
            guard group.isStreaming, isExpanded else { return }
            // Collapse after the view settles so height shrinks smoothly
            // rather than causing an instant content-height drop + scroll jump
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(.easeOut(duration: 0.25)) {
                    isExpanded = false
                }
            }
        }
        .contextMenu {
            Button("Expand All") {
                withAnimation(.easeInOut(duration: ChatTokens.durNormal)) {
                    isExpanded = true
                    forceExpandAll = true
                }
            }

            Button("Copy All Outputs") {
                let allOutput = group.toolCalls
                    .compactMap(\.toolCall.copyableOutputText)
                    .joined(separator: "\n\n")
                guard !allOutput.isEmpty else {
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(allOutput, forType: .string)
            }
        }
    }

    // MARK: - Status Dot

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        if group.toolCalls.contains(where: { $0.toolCall.status == .failed }) {
            return ChatTokens.statusError
        }
        if group.toolCalls.contains(where: { $0.toolCall.status == .inProgress || $0.toolCall.status == .pending }) {
            return ChatTokens.statusWarning
        }
        return ChatTokens.statusSuccess
    }

    // MARK: - Tool Kind Icons

    private var toolIcons: some View {
        let kinds = Array(Set(group.toolCalls.compactMap { $0.toolCall.kind })).prefix(4)
        return HStack(spacing: 4) {
            ForEach(Array(kinds), id: \.rawValue) { kind in
                Image(systemName: kind.symbolName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ChatTokens.textMuted)
                    .frame(width: 12, height: 12)
            }
        }
    }

    // MARK: - Exploration Cluster Row

    private func explorationRow(_ cluster: ExplorationCluster) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ChatTokens.textMuted)
            Text(cluster.summaryText)
                .font(.system(size: ChatTokens.captionFontSize))
                .foregroundStyle(ChatTokens.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ChatTokens.surfaceCard)
        )
    }

    private static func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded()))ms"
        }
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(minutes)m \(secs)s"
    }
}
