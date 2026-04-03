import ACPModel
import AppKit
import SwiftUI

struct MessageBubbleView: View {
    let message: MessageTimelineItem
    var renderMarkdown = false

    @State private var isHovering = false
    @State private var copied = false

    var body: some View {
        Group {
            switch message.role {
            case .user:
                userRow
            case .assistant:
                agentRow
            case .system:
                systemRow
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    // MARK: - User Bubble (right-aligned, neutral surface)

    private var userRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 36)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                textContent
                timestamp
            }
            .padding(.horizontal, ChatTokens.bubblePaddingH)
            .padding(.vertical, 10)
            .frame(maxWidth: min(560, 560), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ChatTokens.radiusBubble, style: .continuous)
                    .fill(ChatTokens.surfaceCardStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChatTokens.radiusBubble, style: .continuous)
                    .strokeBorder(ChatTokens.borderSubtle, lineWidth: 1)
            )
            .overlay(alignment: .bottomTrailing) {
                copyButton
                    .offset(y: 16)
            }
        }
    }

    // MARK: - Agent Message (flat, no bubble)

    private var agentRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            textContent
            timestamp
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            copyButton
        }
    }

    // MARK: - System Message (centered caption)

    private var systemRow: some View {
        VStack(spacing: 2) {
            Text(plainText.isEmpty ? "System" : plainText)
                .font(.caption)
                .foregroundStyle(ChatTokens.textMuted)
            timestamp
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shared Elements

    private var textContent: some View {
        Group {
            if renderMarkdown {
                MarkdownView(text: plainText, isStreaming: message.id == "streaming-agent")
            } else {
                Text(plainText.isEmpty ? "..." : plainText)
                    .font(.system(size: ChatTokens.bodyFontSize))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timestamp: some View {
        Text(Self.timestampFormatter.string(from: message.timestamp))
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(ChatTokens.textFaint)
    }

    private var copyButton: some View {
        Button {
            guard !plainText.isEmpty else {
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(plainText, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(copied ? ChatTokens.statusSuccess : ChatTokens.textMuted)
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: ChatTokens.radiusCommandPill, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ChatTokens.radiusCommandPill, style: .continuous)
                        .strokeBorder(ChatTokens.borderSubtle, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .opacity(isHovering || copied ? 1 : 0)
        .animation(.easeOut(duration: ChatTokens.durFast), value: isHovering)
        .animation(.easeOut(duration: ChatTokens.durFast), value: copied)
        .accessibilityLabel(copied ? "Copied" : "Copy message")
    }

    private var plainText: String {
        message.content.compactMap { block in
            switch block {
            case let .text(content):
                return content.text
            default:
                return nil
            }
        }
        .joined()
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
