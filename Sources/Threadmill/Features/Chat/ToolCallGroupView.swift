import ACPModel
import AppKit
import SwiftUI

struct ToolCallGroupView: View {
    let group: ToolCallGroup
    var childToolCalls: [String: [ToolCallTimelineItem]] = [:]

    @State private var isExpanded = false
    @State private var forceExpandAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    statusDot
                    toolIcons
                    Text("\(group.toolCalls.count) tool calls")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.displayItems) { displayItem in
                        switch displayItem {
                        case let .toolCall(item):
                            ToolCallView(
                                item: item,
                                childToolCalls: childToolCalls[item.id] ?? [],
                                forceExpanded: forceExpandAll
                            )
                        case let .exploration(cluster):
                            explorationRow(cluster)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .contextMenu {
            Button("Expand All") {
                withAnimation(.easeInOut(duration: 0.16)) {
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

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
    }

    private var statusColor: Color {
        if group.toolCalls.contains(where: { $0.toolCall.status == .failed }) {
            return .red
        }
        if group.toolCalls.contains(where: { $0.toolCall.status == .inProgress || $0.toolCall.status == .pending }) {
            return .yellow
        }
        return .green
    }

    private var toolIcons: some View {
        let kinds = Array(Set(group.toolCalls.compactMap { $0.toolCall.kind })).prefix(4)
        return HStack(spacing: 4) {
            ForEach(Array(kinds), id: \.rawValue) { kind in
                Image(systemName: kind.symbolName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
            }
        }
    }

    private func explorationRow(_ cluster: ExplorationCluster) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(cluster.summaryText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
