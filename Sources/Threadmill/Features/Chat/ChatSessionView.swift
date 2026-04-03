import ACPModel
import SwiftUI
import os

struct ChatSessionView: View {
    var viewModel: ChatSessionViewModel
    @State private var showingPlanSidebar = false

    private static let sidebarWidth: CGFloat = 260

    var body: some View {
        let _ = Logger.chat.info("ChatSessionView body — viewModel.sessionID=\(viewModel.sessionID ?? "nil", privacy: .public), isStreaming=\(viewModel.isStreaming, privacy: .public)")
        HStack(spacing: 0) {
            // Chat column
            VStack(spacing: 0) {
                ChatMessageList(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if case .starting = viewModel.sessionState {
                    ChatProcessingIndicator()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }

                if case let .failed(error) = viewModel.sessionState {
                    HStack(spacing: 10) {
                        Text(error.localizedDescription)
                            .font(.system(size: ChatTokens.captionFontSize))
                            .foregroundStyle(ChatTokens.statusError)
                            .lineLimit(2)
                        Button("Retry") {
                            Task { await viewModel.retrySession() }
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if viewModel.isStreaming {
                    ChatProcessingIndicator(turnStartedAt: viewModel.turnStartedAt)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }

                if let plan = viewModel.currentPlan, !plan.entries.isEmpty {
                    planFAB(plan: plan)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                }

                ChatInputBar(viewModel: viewModel)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
            }

            // Plan sidebar — full height
            if showingPlanSidebar, let plan = viewModel.currentPlan, !plan.entries.isEmpty {
                Rectangle()
                    .fill(ChatTokens.borderSubtle)
                    .frame(width: 1)

                PlanSidebarView(plan: plan) {
                    withAnimation(.easeInOut(duration: ChatTokens.durNormal)) {
                        showingPlanSidebar = false
                    }
                }
                .frame(width: Self.sidebarWidth)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(ChatTokens.surfaceMessages)
        .background {
            // Cmd+.: cancel streaming (macOS standard cancel)
            Button("") {
                guard viewModel.isStreaming else { return }
                Task { await viewModel.cancelCurrentPrompt() }
            }
            .keyboardShortcut(".", modifiers: .command)
            .hidden()
        }
        .onAppear {
            Logger.chat.info("ChatSessionView appeared — viewModel.sessionID=\(viewModel.sessionID ?? "nil", privacy: .public)")
        }
        .onChange(of: viewModel.currentPlan == nil) { _, hasNoPlan in
            if hasNoPlan {
                withAnimation(.easeInOut(duration: ChatTokens.durNormal)) {
                    showingPlanSidebar = false
                }
            }
        }
    }

    private func planFAB(plan: Plan) -> some View {
        let completed = plan.entries.filter { $0.status == .completed }.count
        return Button {
            withAnimation(.easeInOut(duration: ChatTokens.durNormal)) {
                showingPlanSidebar.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(completed)/\(plan.entries.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(ChatTokens.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(ChatTokens.borderSubtle, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }
}

// MARK: - Plan Sidebar

private struct PlanSidebarView: View {
    let plan: Plan
    let onClose: () -> Void

    private var completionRatio: Double {
        guard !plan.entries.isEmpty else { return 0 }
        let completed = plan.entries.filter { $0.status == .completed }.count
        return Double(completed) / Double(plan.entries.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Plan")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChatTokens.textStrong)

                Spacer(minLength: 0)

                Text("\(Int((completionRatio * 100).rounded()))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(ChatTokens.textSubtle)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(ChatTokens.textMuted)
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ChatTokens.surfaceCardStrong)
                    Capsule()
                        .fill(ChatTokens.accentGradient)
                        .frame(width: max(4, geometry.size.width * completionRatio))
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 14)

            // Entries
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(plan.entries.enumerated()), id: \.offset) { _, entry in
                        PlanSidebarEntryRow(entry: entry)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(ChatTokens.surfaceMessages)
    }
}

private struct PlanSidebarEntryRow: View {
    let entry: PlanEntry

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: statusSymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 14)
                .padding(.top, 2)

            Text(entry.content)
                .font(.system(size: 12))
                .foregroundStyle(
                    entry.status == .completed || entry.status == .cancelled
                        ? ChatTokens.textSubtle
                        : ChatTokens.textPrimary
                )
                .strikethrough(entry.status == .cancelled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    private var statusSymbol: String {
        switch entry.status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "arrow.right.circle"
        case .pending: "circle"
        case .cancelled: "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .completed: ChatTokens.statusSuccess
        case .inProgress: ChatTokens.borderAccent
        case .pending: ChatTokens.textSubtle
        case .cancelled: ChatTokens.statusError
        }
    }
}
