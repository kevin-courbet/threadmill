import ACPModel
import SwiftUI

struct PlanCardView: View {
    let plan: Plan

    @State private var isExpanded = false

    private var completedCount: Int {
        plan.entries.filter { $0.status == .completed }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: ChatTokens.durNormal)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ChatTokens.textMuted)

                    Text("Plan · \(completedCount)/\(plan.entries.count) done")
                        .font(.system(size: ChatTokens.metaFontSize, weight: .semibold))
                        .foregroundStyle(ChatTokens.textPrimary)

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ChatTokens.textSubtle)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(plan.entries.enumerated()), id: \.offset) { _, entry in
                        PlanEntryRow(entry: entry)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: ChatTokens.radiusCard, style: .continuous)
                .fill(ChatTokens.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChatTokens.radiusCard, style: .continuous)
                .strokeBorder(ChatTokens.borderSubtle, lineWidth: 1)
        )
    }
}

private struct PlanEntryRow: View {
    let entry: PlanEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: statusSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 14)

            Circle()
                .fill(priorityColor)
                .frame(width: 6, height: 6)
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
