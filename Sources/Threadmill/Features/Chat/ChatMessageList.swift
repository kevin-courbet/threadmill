import SwiftUI

struct ChatMessageList: View {
    let viewModel: ChatSessionViewModel

    @State private var loadedItemCount = 140
    @State private var isNearBottom = true
    @State private var userScrolledUp = false

    private let bottomAnchorID = "chat-timeline-bottom-anchor"
    private let initialWindow = 140
    private let windowStep = 120

    private var items: [TimelineItem] {
        viewModel.timelineItems
    }

    private var displayRange: Range<Int> {
        let end = items.count
        let start = max(0, end - min(max(loadedItemCount, initialWindow), end))
        return start ..< end
    }

    private var displayItems: [TimelineItem] {
        Array(items[displayRange])
    }

    private var lastRenderID: String {
        items.last?.renderId ?? ""
    }

    private var childToolCalls: [String: [ToolCallTimelineItem]] {
        var grouped: [String: [ToolCallTimelineItem]] = [:]
        for call in viewModel.toolCallsByID.values {
            guard let parentID = call.toolCall.parentToolCallId else {
                continue
            }
            grouped[parentID, default: []].append(call)
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.timestamp < $1.timestamp }
        }
        return grouped
    }

    private var remainingItemCount: Int {
        displayRange.lowerBound
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: ChatTokens.messageSpacing) {
                        if remainingItemCount > 0 {
                            loadMoreButton(proxy: proxy)
                        }

                        ForEach(displayItems, id: \.stableId) { item in
                            itemView(item)
                                .id(item.stableId)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                            .background(
                                ScrollBottomObserver(
                                    onNearBottomChange: { nearBottom in
                                        isNearBottom = nearBottom
                                    },
                                    onUserScrolledUpChange: { scrolledUp in
                                        userScrolledUp = scrolledUp
                                    }
                                )
                                .frame(width: 0, height: 0)
                            )
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }

                // Scroll-to-bottom FAB
                if userScrolledUp {
                    Button {
                        userScrolledUp = false
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(ChatTokens.textMuted)
                            .padding(10)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(ChatTokens.borderSubtle, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .onAppear {
                loadedItemCount = min(initialWindow, items.count)
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: items.count) { oldCount, newCount in
                if oldCount == 0 {
                    loadedItemCount = min(initialWindow, newCount)
                } else if !isNearBottom {
                    loadedItemCount += max(0, newCount - oldCount)
                }

                guard viewModel.isStreaming, !userScrolledUp else {
                    return
                }
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: viewModel.isStreaming) { _, streaming in
                guard streaming, !userScrolledUp else {
                    return
                }
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: lastRenderID) { _, _ in
                guard viewModel.isStreaming, !userScrolledUp else {
                    return
                }
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: TimelineItem) -> some View {
        switch item {
        case let .message(message):
            MessageBubbleView(message: message, renderMarkdown: message.role == .assistant)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .toolCall(toolCall):
            ToolCallView(item: toolCall, childToolCalls: childToolCalls[toolCall.id] ?? [])
        case let .thought(thought):
            ThoughtView(item: thought, isStreaming: viewModel.isStreaming)
        case let .toolCallGroup(group):
            ToolCallGroupView(group: group, childToolCalls: childToolCalls)
        case .turnSummary:
            EmptyView()
        }
    }

    private func loadMoreButton(proxy: ScrollViewProxy) -> some View {
        Button {
            guard remainingItemCount > 0 else {
                return
            }

            let anchorID = displayItems.first?.stableId
            loadedItemCount += min(windowStep, remainingItemCount)

            Task { @MainActor in
                await Task.yield()
                if let anchorID {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            }
        } label: {
            Text("Load more (\(remainingItemCount) remaining)")
                .font(.system(size: ChatTokens.captionFontSize))
                .foregroundStyle(ChatTokens.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ChatTokens.surfaceCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(ChatTokens.borderSubtle, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}
