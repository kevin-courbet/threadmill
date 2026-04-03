import ACPModel
import AppKit
import SwiftUI

struct ToolCallView: View {
    let item: ToolCallTimelineItem
    var childToolCalls: [ToolCallTimelineItem] = []
    var depth: Int = 0
    var forceExpanded: Bool = false

    @State private var isExpanded: Bool

    init(item: ToolCallTimelineItem, childToolCalls: [ToolCallTimelineItem] = [], depth: Int = 0, forceExpanded: Bool = false) {
        self.item = item
        self.childToolCalls = childToolCalls
        self.depth = depth
        self.forceExpanded = forceExpanded

        let call = item.toolCall
        let autoExpand = call.kind == .edit || call.kind == .delete || call.content.contains {
            if case .diff = $0 {
                return true
            }
            return false
        }
        _isExpanded = State(initialValue: forceExpanded || autoExpand)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row: status dot + kind icon + title + child count + chevron
            Button {
                withAnimation(.easeInOut(duration: ChatTokens.durNormal)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    statusDot

                    Image(systemName: item.toolCall.resolvedKind.symbolName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ChatTokens.textMuted)
                        .frame(width: 14, height: 14)

                    Text(displayTitle)
                        .font(.system(size: ChatTokens.codeFontSize, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .foregroundStyle(ChatTokens.textPrimary)

                    if !childToolCalls.isEmpty {
                        Text("\(childToolCalls.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ChatTokens.textMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(ChatTokens.surfaceCard, in: Capsule())
                    }

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ChatTokens.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded body
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let rawInput = item.toolCall.rawInput?.formattedString {
                        section(title: "Input") {
                            CodeBlockView(code: rawInput, language: "json")
                        }
                    }

                    ForEach(Array(item.toolCall.content.enumerated()), id: \.offset) { _, content in
                        contentView(content)
                    }

                    if let rawOutput = item.toolCall.rawOutput?.formattedString, item.toolCall.content.isEmpty {
                        section(title: "Output") {
                            renderTextContent(rawOutput)
                        }
                    }

                    if !childToolCalls.isEmpty {
                        section(title: "Nested") {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(childToolCalls) { child in
                                    ToolCallView(item: child, depth: depth + 1, forceExpanded: forceExpanded)
                                }
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .toolCallCard()
        .padding(.leading, CGFloat(depth) * 14)
    }

    // MARK: - Content Views

    @ViewBuilder
    private func contentView(_ content: ToolCallContent) -> some View {
        switch content {
        case let .content(block):
            switch block {
            case let .text(text):
                section(title: "Content") {
                    renderTextContent(text.text)
                }
            default:
                EmptyView()
            }
        case let .diff(diff):
            section(title: "Diff") {
                InlineDiffView(diff: diff)
            }
        case let .terminal(terminal):
            section(title: "Terminal") {
                terminalOutput(terminal.terminalId)
            }
        }
    }

    // Terminal output area matching CodexMonitor's .tool-inline-terminal
    private func terminalOutput(_ terminalId: String) -> some View {
        ScrollView(.horizontal) {
            Text("terminal: \(terminalId)")
                .font(.system(size: ChatTokens.codeFontSize, weight: .regular, design: .monospaced))
                .foregroundStyle(ChatTokens.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .textSelection(.enabled)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ChatTokens.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(ChatTokens.borderHeavy, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func renderTextContent(_ text: String) -> some View {
        if InlineDiffView.looksLikeUnifiedDiff(text) {
            InlineDiffView(text: text)
        } else if let fenced = fencedCode(in: text) {
            CodeBlockView(code: fenced.code, language: fenced.language ?? languageHint)
        } else if looksLikeCode(text) {
            CodeBlockView(code: text, language: languageHint)
        } else {
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: ChatTokens.codeFontSize, design: .monospaced))
                    .foregroundStyle(ChatTokens.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .textSelection(.enabled)
            }
            .background(
                RoundedRectangle(cornerRadius: ChatTokens.radiusCommandPill, style: .continuous)
                    .fill(ChatTokens.surfaceCommand)
            )
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ChatTokens.textFaint)
                .tracking(0.8)
            content()
        }
    }

    // MARK: - Status Dot

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch item.toolCall.status {
        case .completed:
            return ChatTokens.statusSuccess
        case .inProgress, .pending:
            return ChatTokens.statusWarning
        case .failed:
            return ChatTokens.statusError
        }
    }

    // MARK: - Helpers

    private var languageHint: String? {
        if let path = item.toolCall.locations?.compactMap(\.path).first {
            return URL(fileURLWithPath: path).pathExtension
        }
        return nil
    }

    private func fencedCode(in text: String) -> (language: String?, code: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else {
            return nil
        }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else {
            return nil
        }
        let language = String(first.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (language.isEmpty ? nil : language, lines.dropFirst().dropLast().joined(separator: "\n"))
    }

    private func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 2 else {
            return false
        }
        let codeSignals = ["{", "}", "=>", "func ", "let ", "var ", "class ", "import ", "def ", "$ ", "SELECT "]
        return lines.contains { line in
            codeSignals.contains { line.localizedCaseInsensitiveContains($0) }
        }
    }
}

private extension AnyCodable {
    var formattedString: String? {
        if let string = value as? String {
            return string
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8)
        {
            return string
        }
        return String(describing: value)
    }
}
