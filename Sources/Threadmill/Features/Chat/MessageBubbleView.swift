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

    private var userRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 36)
            VStack(alignment: .leading, spacing: 6) {
                textContent
                timestamp
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 420, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topTrailing) {
                copyButton
                    .padding(8)
            }
        }
    }

    private var agentRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            textContent
            timestamp
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            copyButton
        }
    }

    private var systemRow: some View {
        VStack(spacing: 2) {
            Text(plainText.isEmpty ? "System" : plainText)
                .font(.caption)
                .foregroundStyle(.secondary)
            timestamp
        }
        .frame(maxWidth: .infinity)
    }

    private var textContent: some View {
        Group {
            if renderMarkdown {
                MarkdownView(text: plainText, isStreaming: message.id == "streaming-agent")
            } else {
                Text(plainText.isEmpty ? "..." : plainText)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timestamp: some View {
        Text(Self.timestampFormatter.string(from: message.timestamp))
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(.secondary)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? Color.green : .secondary)
                .padding(5)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isHovering || copied ? 1 : 0)
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
