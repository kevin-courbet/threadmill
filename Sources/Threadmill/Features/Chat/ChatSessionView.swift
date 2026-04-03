import SwiftUI
import os

struct ChatSessionView: View {
    var viewModel: ChatSessionViewModel
    @State private var showingPlanPanel = false

    var body: some View {
        let _ = Logger.chat.info("ChatSessionView body — viewModel.sessionID=\(viewModel.sessionID ?? "nil", privacy: .public), isStreaming=\(viewModel.isStreaming, privacy: .public)")
        VStack(spacing: 0) {
            if let plan = viewModel.currentPlan, !plan.entries.isEmpty {
                planToggleBar
                    .padding(.horizontal, 18)
                    .padding(.top, 12)

                if showingPlanPanel {
                    PlanPanelView(plan: plan)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ChatMessageList(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ChatMessageList(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if case .starting = viewModel.sessionState {
                ChatProcessingIndicator(thoughtText: "Starting session\u{2026}")
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
                ChatProcessingIndicator(
                    thoughtText: viewModel.currentThought,
                    turnStartedAt: viewModel.turnStartedAt
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.bottom, 4)
                .transition(.opacity)
            }

            ChatInputBar(viewModel: viewModel)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 14)
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
                showingPlanPanel = false
            }
        }
    }

    private var planToggleBar: some View {
        HStack(spacing: 8) {
            planToggleButton(title: "Chat", icon: "text.bubble", selected: !showingPlanPanel) {
                showingPlanPanel = false
            }
            planToggleButton(title: "Plan", icon: "list.bullet.clipboard", selected: showingPlanPanel) {
                showingPlanPanel = true
            }
            Spacer(minLength: 0)
        }
    }

    private func planToggleButton(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: ChatTokens.metaFontSize, weight: .semibold))
                .foregroundStyle(selected ? ChatTokens.textStrong : ChatTokens.textMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? ChatTokens.surfaceCardStrong : ChatTokens.surfaceCard)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(selected ? ChatTokens.borderHeavy : ChatTokens.borderSubtle, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
