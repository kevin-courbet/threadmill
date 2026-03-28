import SwiftUI

struct ChatSessionView: View {
    @State var viewModel: ChatSessionViewModel

    private var sessionStateLabel: String {
        switch viewModel.sessionState {
        case .starting:
            return "starting"
        case .ready:
            return "ready"
        case .failed:
            return "failed"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatMessageList(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.isStreaming {
                ChatProcessingIndicator(thoughtText: viewModel.currentThought)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }

            switch viewModel.sessionState {
            case .starting:
                ChatProcessingIndicator(thoughtText: "Starting chat session…")
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
            case let .failed(error):
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
            case .ready:
                EmptyView()
            }

            ChatInputBar(viewModel: viewModel)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.session.state")
        .accessibilityValue(sessionStateLabel)
        .background {
            // Cmd+.: cancel streaming (macOS standard cancel)
            Button("") {
                guard viewModel.isStreaming else { return }
                Task { await viewModel.cancelCurrentPrompt() }
            }
            .keyboardShortcut(".", modifiers: .command)
            .hidden()
        }
    }
}
