import SwiftUI

struct ThoughtView: View {
    let item: ThoughtTimelineItem
    let isStreaming: Bool

    @State private var isExpanded: Bool

    init(item: ThoughtTimelineItem, isStreaming: Bool) {
        self.item = item
        self.isStreaming = isStreaming
        _isExpanded = State(initialValue: isStreaming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: ChatTokens.durNormal)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ChatTokens.textFaint)

                    Text("Thinking")
                        .font(.system(size: ChatTokens.captionFontSize, weight: .semibold))
                        .foregroundStyle(ChatTokens.textMuted)

                    Text("· \(item.text.count) chars")
                        .font(.system(size: ChatTokens.captionFontSize, weight: .regular, design: .monospaced))
                        .foregroundStyle(ChatTokens.textFaint)

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ChatTokens.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView {
                    Text(item.text)
                        .font(.system(size: ChatTokens.codeFontSize, design: .monospaced))
                        .foregroundStyle(ChatTokens.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(ChatTokens.surfaceCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(ChatTokens.borderSubtle, lineWidth: 1)
                )
                .padding(.leading, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ChatTokens.surfaceCard.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ChatTokens.borderSubtle, lineWidth: 1)
        )
        .onChange(of: isStreaming) { _, streaming in
            withAnimation(.easeInOut(duration: ChatTokens.durNormal)) {
                isExpanded = streaming
            }
        }
    }
}
