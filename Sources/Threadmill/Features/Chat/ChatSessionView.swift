import SwiftUI
import os

struct ChatSessionView: View {
    var viewModel: ChatSessionViewModel

    var body: some View {
        let _ = Logger.chat.info("ChatSessionView body — viewModel.sessionID=\(viewModel.sessionID ?? "nil", privacy: .public), isStreaming=\(viewModel.isStreaming, privacy: .public)")
        VStack(spacing: 0) {
            ChatMessageList(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
    }
}
