import AppKit
import SwiftUI

struct MessageBubbleView: View {
    let message: OCMessage

    @State private var isHovering = false
    @State private var copyConfirmed = false

    private var role: ChatMessageRole {
        ChatMessageRole(rawValue: message.role.lowercased()) ?? .assistant
    }

    private var segments: [MessageSegment] {
        var values: [MessageSegment] = []
        var pendingTools: [OCMessagePart] = []

        func flushTools() {
            guard !pendingTools.isEmpty else {
                return
            }
            values.append(.tools(pendingTools))
            pendingTools.removeAll(keepingCapacity: true)
        }

        for part in message.parts {
            if part.isToolPart {
                pendingTools.append(part)
                continue
            }

            flushTools()

            if let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                values.append(.text(text))
            } else if !part.raw.isEmpty, let rawDump = chatFormattedJSON(part.raw.foundationValue) {
                values.append(.raw(rawDump))
            }
        }

        flushTools()
        return values
    }

    var body: some View {
        Group {
            switch role {
            case .user:
                userBody
            case .assistant:
                assistantBody
            case .system:
                systemBody
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.95).combined(with: .opacity),
                removal: .opacity
            )
        )
    }

    private var userBody: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 40)

            VStack(alignment: .leading, spacing: 8) {
                if segments.isEmpty {
                    Text("(empty prompt)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(segments.indices, id: \.self) { index in
                        segmentView(segments[index], useMarkdown: false)
                    }
                }

                if let timestampText {
                    Text(timestampText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 420, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                copyButton
                    .padding(8)
            }
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Assistant")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let timestampText {
                    Text(timestampText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                copyButton
            }

            if segments.isEmpty {
                Text("Thinking...")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(segments.indices, id: \.self) { index in
                    segmentView(segments[index], useMarkdown: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var systemBody: some View {
        VStack(spacing: 2) {
            Text(flattenedText.isEmpty ? "System" : flattenedText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.9))

            if let timestampText {
                Text(timestampText)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func segmentView(_ segment: MessageSegment, useMarkdown: Bool) -> some View {
        switch segment {
        case let .text(text):
            if useMarkdown {
                MarkdownView(text: text)
            } else {
                Text(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

        case let .raw(raw):
            CodeBlockView(code: raw, language: "json")

        case let .tools(parts):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(parts) { part in
                    ToolCallView(part: part)
                }
            }
        }
    }

    private var copyButton: some View {
        Button {
            guard !flattenedText.isEmpty else {
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(flattenedText, forType: .string)
            copyConfirmed = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copyConfirmed = false
            }
        } label: {
            Image(systemName: copyConfirmed ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copyConfirmed ? Color.green : .secondary)
                .padding(5)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isHovering || copyConfirmed ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityLabel(copyConfirmed ? "Copied" : "Copy message")
    }

    private var timestampText: String? {
        guard let time = message.time?.completed ?? message.time?.created else {
            return nil
        }
        return MessageBubbleTimestampFormatter.shared.string(from: Date(timeIntervalSince1970: time))
    }

    private var flattenedText: String {
        let chunks: [String] = message.parts.compactMap { part in
            if let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
            if !part.raw.isEmpty {
                return chatFormattedJSON(part.raw.foundationValue)
            }
            return nil
        }
        return chunks.joined(separator: "\n\n")
    }
}

private enum ChatMessageRole: String {
    case user
    case assistant
    case system
}

private enum MessageSegment {
    case text(String)
    case raw(String)
    case tools([OCMessagePart])
}

private final class MessageBubbleTimestampFormatter {
    static let shared: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
