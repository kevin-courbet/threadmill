import ACPModel
import AppKit
import SwiftUI

struct ToolCallView: View {
    let item: ToolCallTimelineItem
    var childToolCalls: [ToolCallTimelineItem] = []
    var depth: Int = 0
    var forceExpanded: Bool = false
    var isGrouped: Bool = false

    @State private var isExpanded: Bool

    init(item: ToolCallTimelineItem, childToolCalls: [ToolCallTimelineItem] = [], depth: Int = 0, forceExpanded: Bool = false, isGrouped: Bool = false) {
        self.item = item
        self.childToolCalls = childToolCalls
        self.depth = depth
        self.forceExpanded = forceExpanded
        self.isGrouped = isGrouped

        let call = item.toolCall
        let autoExpand = call.kind == .edit || call.kind == .delete || call.content.contains {
            if case .diff = $0 { return true }
            return false
        }
        _isExpanded = State(initialValue: forceExpanded || autoExpand)
    }

    private var kind: ToolKind { item.toolCall.resolvedKind }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            if isExpanded { expandedBody }
        }
        .padding(.horizontal, isGrouped ? 0 : 12)
        .padding(.vertical, isGrouped ? 6 : 12)
        .if(!isGrouped) { $0.toolCallCard() }
        .padding(.leading, CGFloat(depth) * 14)
    }

    // MARK: - Header

    private var headerRow: some View {
        Button {
            withAnimation(.easeInOut(duration: ChatTokens.durNormal)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                statusDot

                Image(systemName: kind.symbolName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusIconColor)
                    .frame(width: 14, height: 14)

                // Contextual summary label
                Text(summaryLabel)
                    .font(.system(size: ChatTokens.captionFontSize, weight: .medium))
                    .foregroundStyle(ChatTokens.textMuted)

                // Primary value (path, command, or title)
                Text(summaryValue)
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

                if let duration = item.durationSeconds {
                    Text(Self.formatDuration(duration))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(ChatTokens.textFaint)
                }

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ChatTokens.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summary (contextual label + value per kind)

    private var summaryLabel: String {
        switch kind {
        case .read: return "read"
        case .edit: return "edited"
        case .delete: return "deleted"
        case .move: return "moved"
        case .search: return "searched"
        case .execute: return "ran"
        case .think: return "thought"
        case .fetch: return "fetched"
        case .plan: return "planned"
        default: return "tool"
        }
    }

    private var summaryValue: String {
        // For file operations: show basename from locations
        if let path = primaryPath {
            let basename = URL(fileURLWithPath: path).lastPathComponent
            let extraCount = (item.toolCall.locations?.compactMap(\.path).count ?? 1) - 1
            return extraCount > 0 ? "\(basename) +\(extraCount)" : basename
        }

        // For commands: clean the command string
        if kind == .execute {
            return Self.cleanCommandText(extractInputString("command") ?? extractInputString("input") ?? item.toolCall.title)
        }

        // For search: show the query
        if kind == .search {
            return extractInputString("pattern") ?? extractInputString("query") ?? extractInputString("regex") ?? item.toolCall.title
        }

        // For fetch: show the URL
        if kind == .fetch {
            return extractInputString("url") ?? item.toolCall.title
        }

        return displayTitle
    }

    // MARK: - Expanded Body (per-kind rendering)

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Kind-specific input display
            switch kind {
            case .execute:
                commandExpandedBody
            case .read:
                readExpandedBody
            case .edit, .delete, .move:
                fileChangeExpandedBody
            default:
                genericExpandedBody
            }

            // Child tool calls
            if !childToolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(childToolCalls) { child in
                        ToolCallView(item: child, depth: depth + 1, forceExpanded: forceExpanded)
                    }
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Command Execution

    private var commandExpandedBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Full command when expanded
            if let cmd = extractInputString("command") ?? extractInputString("input") {
                Text(Self.cleanCommandText(cmd))
                    .font(.system(size: ChatTokens.codeFontSize, design: .monospaced))
                    .foregroundStyle(ChatTokens.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(ChatTokens.surfaceCommand)
                    )
            }

            // cwd if present
            if let cwd = extractInputString("workdir") ?? extractInputString("cwd") ?? extractInputString("working_directory") {
                HStack(spacing: 4) {
                    Text("cwd:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ChatTokens.textFaint)
                    Text(cwd)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ChatTokens.textMuted)
                        .lineLimit(1)
                }
            }

            // Output as terminal block
            ForEach(Array(item.toolCall.content.enumerated()), id: \.offset) { _, content in
                contentView(content)
            }

            if let rawOutput = item.toolCall.rawOutput?.formattedString, item.toolCall.content.isEmpty {
                terminalOutputBlock(rawOutput)
            }
        }
    }

    // MARK: - Read

    private var readExpandedBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Show full path
            if let path = primaryPath {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ChatTokens.textMuted)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            // Content as code block
            ForEach(Array(item.toolCall.content.enumerated()), id: \.offset) { _, content in
                contentView(content)
            }

            if let rawOutput = item.toolCall.rawOutput?.formattedString, item.toolCall.content.isEmpty {
                CodeBlockView(code: rawOutput, language: languageHint)
            }
        }
    }

    // MARK: - File Change (edit/delete/move)

    private var fileChangeExpandedBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            // File change badges
            if let locations = item.toolCall.locations, !locations.isEmpty {
                ForEach(Array(locations.enumerated()), id: \.offset) { _, location in
                    if let path = location.path {
                        HStack(spacing: 6) {
                            fileChangeBadge
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.system(size: ChatTokens.codeFontSize, weight: .medium, design: .monospaced))
                                .foregroundStyle(ChatTokens.textPrimary)
                            Text(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(ChatTokens.textFaint)
                                .lineLimit(1)
                        }
                    }
                }
            }

            // Diffs and content
            ForEach(Array(item.toolCall.content.enumerated()), id: \.offset) { _, content in
                contentView(content)
            }

            if let rawOutput = item.toolCall.rawOutput?.formattedString, item.toolCall.content.isEmpty {
                renderTextContent(rawOutput)
            }
        }
    }

    private var fileChangeBadge: some View {
        let (label, color): (String, Color) = {
            switch kind {
            case .edit: return ("MOD", ChatTokens.statusWarning)
            case .delete: return ("DEL", ChatTokens.statusError)
            case .move: return ("MOV", Color.blue)
            default: return ("ADD", ChatTokens.statusSuccess)
            }
        }()
        return Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.15))
            )
    }

    // MARK: - Generic (search, fetch, think, other)

    private var genericExpandedBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Show relevant input fields (not raw JSON dump)
            if let detail = smartInputDetail {
                Text(detail)
                    .font(.system(size: ChatTokens.codeFontSize, design: .monospaced))
                    .foregroundStyle(ChatTokens.textMuted)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(ChatTokens.surfaceCommand)
                    )
            }

            ForEach(Array(item.toolCall.content.enumerated()), id: \.offset) { _, content in
                contentView(content)
            }

            if let rawOutput = item.toolCall.rawOutput?.formattedString, item.toolCall.content.isEmpty {
                renderOutputBlock(rawOutput)
            }
        }
    }

    /// Extract a meaningful single-line detail from input, avoiding a raw JSON dump.
    private var smartInputDetail: String? {
        // For search: show pattern + path
        if kind == .search {
            let pattern = extractInputString("pattern") ?? extractInputString("query") ?? extractInputString("regex")
            let path = extractInputString("path") ?? extractInputString("include")
            if let pattern {
                return path != nil ? "\(pattern) in \(path!)" : pattern
            }
        }

        // For fetch: show URL
        if kind == .fetch {
            return extractInputString("url")
        }

        // For think: show the thought
        if kind == .think {
            return extractInputString("thought") ?? extractInputString("content")
        }

        return nil
    }

    // MARK: - Content Views

    @ViewBuilder
    private func contentView(_ content: ToolCallContent) -> some View {
        switch content {
        case let .content(block):
            switch block {
            case let .text(text):
                renderOutputBlock(text.text)
            default:
                EmptyView()
            }
        case let .diff(diff):
            InlineDiffView(diff: diff)
        case let .terminal(terminal):
            terminalOutputBlock("terminal: \(terminal.terminalId)")
        }
    }

    /// Terminal-style output block (command output, scrolling)
    private func terminalOutputBlock(_ text: String) -> some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: ChatTokens.codeFontSize, weight: .regular, design: .monospaced))
                .foregroundStyle(ChatTokens.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 200)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ChatTokens.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(ChatTokens.borderHeavy, lineWidth: 1)
        )
    }

    /// Code/text output block (read results, search results, etc.)
    private func renderOutputBlock(_ text: String) -> some View {
        Group {
            if InlineDiffView.looksLikeUnifiedDiff(text) {
                InlineDiffView(text: text)
            } else if let fenced = fencedCode(in: text) {
                CodeBlockView(code: fenced.code, language: fenced.language ?? languageHint)
            } else if kind == .execute {
                terminalOutputBlock(text)
            } else {
                CodeBlockView(code: text, language: languageHint)
            }
        }
    }

    @ViewBuilder
    private func renderTextContent(_ text: String) -> some View {
        if InlineDiffView.looksLikeUnifiedDiff(text) {
            InlineDiffView(text: text)
        } else if let fenced = fencedCode(in: text) {
            CodeBlockView(code: fenced.code, language: fenced.language ?? languageHint)
        } else {
            CodeBlockView(code: text, language: languageHint)
        }
    }

    // MARK: - Status

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch item.toolCall.status {
        case .completed: return ChatTokens.statusSuccess
        case .inProgress, .pending: return ChatTokens.statusWarning
        case .failed: return ChatTokens.statusError
        }
    }

    private var statusIconColor: Color {
        switch item.toolCall.status {
        case .completed: return ChatTokens.statusSuccess
        case .inProgress, .pending: return ChatTokens.statusWarning
        case .failed: return ChatTokens.statusError
        }
    }

    // MARK: - Helpers

    private var displayTitle: String {
        let title = item.toolCall.title
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        if let kind = item.toolCall.kind { return kind.rawValue.capitalized }
        return "Tool \(item.toolCall.id.prefix(6))"
    }

    private var primaryPath: String? {
        item.toolCall.locations?.compactMap(\.path).first
            ?? extractInputString("filePath")
            ?? extractInputString("path")
            ?? extractInputString("file")
    }

    private var languageHint: String? {
        if let path = primaryPath {
            return URL(fileURLWithPath: path).pathExtension
        }
        return nil
    }

    /// Extract a string value from rawInput by key (handles JSON dict).
    private func extractInputString(_ key: String) -> String? {
        guard let raw = item.toolCall.rawInput?.value as? [String: Any] else { return nil }
        return raw[key] as? String
    }

    /// Strip shell wrappers: `bash -lc '...'` and leading `cd /path && `.
    static func cleanCommandText(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip bash -lc '...' or bash -c '...'
        let shellWrappers = ["bash -lc '", "bash -c '", "sh -c '", "sh -lc '"]
        for wrapper in shellWrappers {
            if s.hasPrefix(wrapper), s.hasSuffix("'") {
                s = String(s.dropFirst(wrapper.count).dropLast())
                break
            }
        }
        // Strip leading cd /path &&
        if let range = s.range(of: #"^cd\s+\S+\s*&&\s*"#, options: .regularExpression) {
            s = String(s[range.upperBound...])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    private func fencedCode(in text: String) -> (language: String?, code: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else { return nil }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return nil }
        let language = String(first.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (language.isEmpty ? nil : language, lines.dropFirst().dropLast().joined(separator: "\n"))
    }
}

private extension AnyCodable {
    var formattedString: String? {
        if let string = value as? String { return string }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8)
        {
            return string
        }
        return String(describing: value)
    }
}
