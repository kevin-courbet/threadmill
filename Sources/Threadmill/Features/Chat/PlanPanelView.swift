import ACPModel
import SwiftUI

struct PlanPanelView: View {
    let plan: Plan

    private var completionRatio: Double {
        guard !plan.entries.isEmpty else { return 0 }
        let completed = plan.entries.filter { $0.status == .completed }.count
        return Double(completed) / Double(plan.entries.count)
    }

    private var groupedEntries: [(title: String, status: PlanEntryStatus, entries: [PlanEntry])] {
        [
            ("In Progress", .inProgress, plan.entries.filter { $0.status == .inProgress }),
            ("Pending", .pending, plan.entries.filter { $0.status == .pending }),
            ("Completed", .completed, plan.entries.filter { $0.status == .completed }),
            ("Cancelled", .cancelled, plan.entries.filter { $0.status == .cancelled }),
        ].filter { !$0.entries.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Agent Plan")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ChatTokens.textStrong)

                    Text("\(plan.entries.count) tasks")
                        .font(.system(size: ChatTokens.metaFontSize))
                        .foregroundStyle(ChatTokens.textMuted)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(ChatTokens.surfaceCardStrong)
                            Capsule()
                                .fill(ChatTokens.accentGradient)
                                .frame(width: max(4, geometry.size.width * completionRatio))
                        }
                    }
                    .frame(height: 8)

                    Text("\(Int((completionRatio * 100).rounded()))% complete")
                        .font(.system(size: ChatTokens.captionFontSize))
                        .foregroundStyle(ChatTokens.textSubtle)
                }
                .padding(14)
                .chatCard()

                ForEach(groupedEntries, id: \.status) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ChatTokens.textMuted)

                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                                PlanPanelEntryRow(entry: entry)
                            }
                        }
                    }
                    .padding(14)
                    .chatCard()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }
}

private struct PlanPanelEntryRow: View {
    let entry: PlanEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusSymbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 16)

            Circle()
                .fill(priorityColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            Text(entry.content)
                .font(.system(size: ChatTokens.bodyFontSize))
                .foregroundStyle(ChatTokens.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusSymbol: String {
        switch entry.status {
        case .completed:
            return "checkmark.circle.fill"
        case .inProgress:
            return "arrow.right.circle"
        case .pending:
            return "circle"
        case .cancelled:
            return "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .completed:
            return ChatTokens.statusSuccess
        case .inProgress:
            return ChatTokens.borderAccent
        case .pending:
            return ChatTokens.textSubtle
        case .cancelled:
            return ChatTokens.statusError
        }
    }

    private var priorityColor: Color {
        switch entry.priority {
        case .high:
            return ChatTokens.statusError
        case .medium:
            return ChatTokens.statusWarning
        case .low:
            return ChatTokens.textSubtle
        }
    }
}
