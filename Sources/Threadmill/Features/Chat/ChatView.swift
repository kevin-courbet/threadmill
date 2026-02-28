import SwiftUI

struct ChatView: View {
    let threadID: String
    let directory: String

    @State private var viewModel: ChatViewModel
    @State private var draftText = ""
    @State private var viewportHeight: CGFloat = 1
    @State private var isNearBottom = true
    @State private var bottomDistanceBaseline: CGFloat = 0
    @State private var hasBottomDistanceBaseline = false
    @State private var shouldRebaseBottomDistance = false
    @State private var jumpRequestToken = 0
    @State private var hasAppeared = false
    @State private var hoveredConversationID: String?

    init(
        threadID: String,
        directory: String,
        openCodeClient: any OpenCodeManaging,
        chatConversationService: any ChatConversationManaging,
        ensureOpenCodeRunning: (() async throws -> Void)? = nil
    ) {
        self.threadID = threadID
        self.directory = directory
        _viewModel = State(initialValue: ChatViewModel(
            openCodeClient: openCodeClient,
            chatConversationService: chatConversationService,
            ensureOpenCodeRunning: ensureOpenCodeRunning
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            conversationTabBar

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
                isGenerating: viewModel.isGenerating,
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
        .task(id: "\(threadID)::\(directory)") {
            await viewModel.loadConversations(threadID: threadID, directory: directory)
            jumpRequestToken += 1
            shouldRebaseBottomDistance = true
        }
        .onChange(of: viewModel.currentConversation?.id) { _, _ in
            jumpRequestToken += 1
            shouldRebaseBottomDistance = true
            hasBottomDistanceBaseline = false
            isNearBottom = true
        }
    }

    private var conversationTabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(viewModel.conversations.enumerated()), id: \.element.id) { index, conversation in
                conversationTab(conversation, index: index)
            }

            Button {
                Task {
                    await viewModel.createConversation(threadID: threadID, directory: directory)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New conversation")
            .accessibilityIdentifier("chat.tab.add")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.28))
                .frame(height: 0.5)
        }
        .accessibilityIdentifier("chat.tab-bar")
    }

    private func conversationTab(_ conversation: ChatConversation, index: Int) -> some View {
        let isSelected = viewModel.currentConversation?.id == conversation.id
        let isCloseVisible = isSelected || hoveredConversationID == conversation.id
        let title = conversationTitle(conversation, index: index)

        return HStack(spacing: 6) {
            Button {
                Task {
                    await viewModel.selectConversation(conversation)
                }
            } label: {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
            .help(title)

            Button {
                Task {
                    await viewModel.archiveConversation(conversation)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.plain)
            .opacity(isCloseVisible ? 1 : 0)
            .allowsHitTesting(isCloseVisible)
            .padding(.trailing, 8)
            .help("Archive conversation")
            .accessibilityIdentifier("chat.tab.close.\(conversation.id)")
        }
        .frame(minWidth: 110, maxWidth: 220, minHeight: 28, maxHeight: 28, alignment: .leading)
        .background(isSelected ? Color.white.opacity(0.08) : .clear)
        .onHover { hovering in
            hoveredConversationID = hovering ? conversation.id : nil
        }
        .accessibilityIdentifier("chat.tab.\(conversation.id)")
    }

    private func conversationTitle(_ conversation: ChatConversation, index: Int) -> String {
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }

        if index == 0 {
            return "New chat"
        }

        return "Chat \(index + 1)"
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
            updateNearBottomState(measuredDistance: max(0, bottomY - viewportHeight))
        }
    }

    private var shouldAutoScroll: Bool {
        isNearBottom
    }

    private var shouldShowJumpButton: Bool {
        !isNearBottom
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        shouldRebaseBottomDistance = true

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

    private func updateNearBottomState(measuredDistance: CGFloat) {
        if shouldRebaseBottomDistance || !hasBottomDistanceBaseline {
            bottomDistanceBaseline = measuredDistance
            hasBottomDistanceBaseline = true
            shouldRebaseBottomDistance = false
            isNearBottom = true
            return
        }

        let effectiveDistance = max(0, measuredDistance - bottomDistanceBaseline)
        let nearBottomThreshold: CGFloat = 140
        let nearBottom = effectiveDistance < nearBottomThreshold

        if nearBottom, measuredDistance > bottomDistanceBaseline {
            bottomDistanceBaseline = measuredDistance
        }

        isNearBottom = nearBottom
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
