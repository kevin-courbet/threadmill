import SwiftUI

struct ChatView: View {
    let directory: String

    @State private var viewModel: ChatViewModel
    @State private var draftText = ""
    @State private var viewportHeight: CGFloat = 1
    @State private var bottomDistance: CGFloat = 0
    @State private var jumpRequestToken = 0
    @State private var hasAppeared = false

    init(
        directory: String,
        openCodeClient: any OpenCodeManaging,
        ensureOpenCodeRunning: (() async throws -> Void)? = nil
    ) {
        self.directory = directory
        _viewModel = State(initialValue: ChatViewModel(openCodeClient: openCodeClient, ensureOpenCodeRunning: ensureOpenCodeRunning))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                messageList

                if shouldShowJumpButton {
                    Button {
                        jumpRequestToken += 1
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down.circle.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.16), radius: 5, y: 2)
                    .padding(.trailing, 18)
                    .padding(.bottom, 12)
                }
            }

            if let lastError = viewModel.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }

            ChatInputView(
                text: $draftText,
                sessions: viewModel.sessions,
                currentSessionID: viewModel.currentSession?.id,
                isGenerating: viewModel.isGenerating,
                onSelectSession: { sessionID in
                    Task {
                        await viewModel.selectSession(id: sessionID)
                    }
                },
                onCreateSession: {
                    Task {
                        await viewModel.createSession(directory: directory)
                    }
                },
                onSend: sendPrompt,
                onAbort: {
                    Task {
                        await viewModel.abort()
                    }
                }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: directory) {
            await viewModel.loadSessions(directory: directory)
            jumpRequestToken += 1
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            configuredScrollView
                .onChange(of: viewModel.messages) { _, _ in
                    guard shouldAutoScroll else {
                        return
                    }
                    scrollToBottom(proxy: proxy, animated: true)
                }
                .onChange(of: viewModel.streamingParts) { _, _ in
                    guard shouldAutoScroll else {
                        return
                    }
                    scrollToBottom(proxy: proxy, animated: false)
                }
                .onChange(of: viewModel.isGenerating) { _, isGenerating in
                    guard isGenerating || shouldAutoScroll else {
                        return
                    }
                    scrollToBottom(proxy: proxy, animated: true)
                }
                .onChange(of: jumpRequestToken) { _, _ in
                    scrollToBottom(proxy: proxy, animated: true)
                }
                .onAppear {
                    guard !hasAppeared else {
                        return
                    }
                    hasAppeared = true
                    scrollToBottom(proxy: proxy, animated: false)
                }
        }
    }

    private var configuredScrollView: some View {
        Group {
            if #available(macOS 15.0, *) {
                baseScrollView
                    .defaultScrollAnchor(.bottom)
            } else {
                baseScrollView
            }
        }
    }

    private var baseScrollView: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(viewModel.messages) { message in
                    MessageBubbleView(message: message)
                        .id(message.id)
                }

                if viewModel.isGenerating {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)

                        Text("Generating response...")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.08))
                    )
                }

                Color.clear
                    .frame(height: 1)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ChatBottomYPreferenceKey.self,
                                value: geometry.frame(in: .named("chat-scroll")).maxY
                            )
                        }
                    )
                    .id("chat-bottom")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .coordinateSpace(name: "chat-scroll")
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: ChatViewportHeightPreferenceKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(ChatViewportHeightPreferenceKey.self) { height in
            viewportHeight = max(1, height)
        }
        .onPreferenceChange(ChatBottomYPreferenceKey.self) { bottomY in
            bottomDistance = max(0, bottomY - viewportHeight)
        }
    }

    private var shouldAutoScroll: Bool {
        bottomDistance < 140
    }

    private var shouldShowJumpButton: Bool {
        bottomDistance > 220
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo("chat-bottom", anchor: .bottom)
        }

        if animated {
            withAnimation(.easeOut(duration: 0.18), action)
        } else {
            action()
        }
    }

    private func sendPrompt() {
        let outgoingText = draftText
        draftText = ""
        Task {
            await viewModel.sendPrompt(text: outgoingText)
        }
    }
}

private struct ChatViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 1

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatBottomYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
