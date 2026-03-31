import SwiftUI
import os

struct ChatSessionView: View {
    var viewModel: ChatSessionViewModel

    var body: some View {
        let _ = Logger.chat.info("ChatSessionView body — viewModel.sessionID=\(viewModel.sessionID ?? "nil", privacy: .public), isStreaming=\(viewModel.isStreaming, privacy: .public)")
        VStack(spacing: 0) {
            ChatMessageList(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.isStreaming {
                ChatProcessingIndicator(thoughtText: viewModel.currentThought)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }

            ChatInputBar(viewModel: viewModel)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
