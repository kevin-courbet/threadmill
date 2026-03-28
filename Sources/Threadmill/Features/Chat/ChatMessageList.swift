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
                    LazyVStack(spacing: 8) {
                        if remainingItemCount > 0 {
                            loadMoreButton(proxy: proxy)
                        }

                        ForEach(displayItems, id: \.renderId) { item in
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .accessibilityIdentifier("chat.timeline")

                if userScrolledUp {
                    Button {
                        userScrolledUp = false
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .bold))
                            .padding(9)
                    }
                    .buttonStyle(.plain)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(.trailing, 18)
                    .padding(.bottom, 14)
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
        case let .toolCallGroup(group):
            ToolCallGroupView(group: group, childToolCalls: childToolCalls)
        case let .turnSummary(summary):
            TurnSummaryView(summary: summary)
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

}
