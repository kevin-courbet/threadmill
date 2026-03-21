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
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    statusIndicator
                    Image(systemName: item.toolCall.resolvedKind.symbolName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 13, height: 13)

                    Text(item.toolCall.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)

                    if !childToolCalls.isEmpty {
                        Text("\(childToolCalls.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .padding(.leading, CGFloat(depth) * 14)
    }

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
                ScrollView(.horizontal) {
                    Text("terminal: \(terminal.terminalId)")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .textSelection(.enabled)
                }
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
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
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .textSelection(.enabled)
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var languageHint: String? {
        if let path = item.toolCall.locations?.compactMap(\.path).first {
            return URL(fileURLWithPath: path).pathExtension
        }
        return nil
    }

    private var statusIndicator: some View {
        Group {
            switch item.toolCall.status {
            case .completed:
                Image(systemName: "circle.fill")
                    .foregroundStyle(Color.green)
            case .inProgress, .pending:
                Image(systemName: "circle.fill")
                    .foregroundStyle(Color.yellow)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.red)
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .frame(width: 10, height: 10)
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
