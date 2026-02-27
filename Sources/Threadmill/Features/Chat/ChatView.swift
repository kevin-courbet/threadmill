import AppKit
import SwiftUI

struct ChatView: View {
    let directory: String

    @State private var viewModel: ChatViewModel
    @State private var draftText = ""
    @State private var viewportHeight: CGFloat = 1
    @State private var bottomDistance: CGFloat = 0
    @State private var jumpRequestToken = 0
    @State private var hasAppeared = false

    init(
        directory: String,
        openCodeClient: any OpenCodeManaging,
        ensureOpenCodeRunning: (() async throws -> Void)? = nil
    ) {
        self.directory = directory
        _viewModel = State(initialValue: ChatViewModel(openCodeClient: openCodeClient, ensureOpenCodeRunning: ensureOpenCodeRunning))
    }

    var body: some View {
        VStack(spacing: 0) {
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
                sessions: viewModel.sessions,
                currentSessionID: viewModel.currentSession?.id,
                isGenerating: viewModel.isGenerating,
                onSelectSession: { sessionID in
                    Task {
                        await viewModel.selectSession(id: sessionID)
                    }
                },
                onCreateSession: {
                    Task {
                        await viewModel.createSession(directory: directory)
                    }
                },
                onSend: sendPrompt,
                onAbort: {
                    Task {
                        await viewModel.abort()
                    }
                }
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: directory) {
            await viewModel.loadSessions(directory: directory)
            jumpRequestToken += 1
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
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
                bottomDistance = max(0, bottomY - viewportHeight)
            }
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

    private var shouldAutoScroll: Bool {
        bottomDistance < 140
    }

    private var shouldShowJumpButton: Bool {
        bottomDistance > 220
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
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
}

private struct MessageBubbleView: View {
    let message: OCMessage

    private var isUser: Bool {
        message.role.caseInsensitiveCompare("user") == .orderedSame
    }

    private var segments: [MessageSegment] {
        var values: [MessageSegment] = []
        var pendingTools: [OCMessagePart] = []

        func flushTools() {
            if !pendingTools.isEmpty {
                values.append(.tools(pendingTools))
                pendingTools.removeAll(keepingCapacity: true)
            }
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
        HStack(alignment: .top, spacing: 0) {
            if isUser {
                Spacer(minLength: 74)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isUser ? "You" : "Assistant")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    if let timestampText {
                        Text(timestampText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if segments.isEmpty {
                    Text(isUser ? "(empty prompt)" : "Thinking...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(segments.indices, id: \.self) { index in
                        segmentView(segments[index])
                    }
                }
            }
            .frame(maxWidth: isUser ? 560 : .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isUser ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor).opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isUser ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 0.5)
            )

            if !isUser {
                Spacer(minLength: 74)
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: MessageSegment) -> some View {
        switch segment {
        case let .text(text):
            if isUser {
                Text(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                MarkdownView(text: text)
            }

        case let .raw(raw):
            CodeBlockView(code: raw, language: "json")

        case let .tools(parts):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(parts.count == 1 ? "Tool call" : "Tool calls (\(parts.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(parts) { part in
                        ToolCallView(part: part)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.08))
            )
        }
    }

    private var timestampText: String? {
        guard let time = message.time?.completed ?? message.time?.created else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: time))
    }
}

private enum MessageSegment {
    case text(String)
    case raw(String)
    case tools([OCMessagePart])
}

private struct MarkdownView: View {
    let text: String

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, content):
            Text(attributedInline(content))
                .font(level == 2 ? .title3.weight(.semibold) : .headline.weight(.semibold))
                .textSelection(.enabled)

        case let .paragraph(content):
            Text(attributedInline(content))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case let .unordered(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(attributedInline(items[index]))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.body)

        case let .ordered(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(item.number).")
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Text(attributedInline(item.text))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.body)

        case let .code(language, code):
            CodeBlockView(code: code, language: language)
        }
    }

    private func attributedInline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }
}

private struct MarkdownOrderedItem {
    let number: Int
    let text: String
}

private enum MarkdownBlock {
    case heading(Int, String)
    case paragraph(String)
    case unordered([String])
    case ordered([MarkdownOrderedItem])
    case code(String?, String)
}

private enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var unordered: [String] = []
        var ordered: [MarkdownOrderedItem] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCodeBlock = false

        func flushParagraph() {
            guard !paragraph.isEmpty else {
                return
            }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll(keepingCapacity: true)
        }

        func flushLists() {
            if !unordered.isEmpty {
                blocks.append(.unordered(unordered))
                unordered.removeAll(keepingCapacity: true)
            }
            if !ordered.isEmpty {
                blocks.append(.ordered(ordered))
                ordered.removeAll(keepingCapacity: true)
            }
        }

        func flushCode() {
            blocks.append(.code(codeLanguage, codeLines.joined(separator: "\n")))
            codeLines.removeAll(keepingCapacity: true)
            codeLanguage = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inCodeBlock {
                if trimmed.hasPrefix("```") {
                    inCodeBlock = false
                    flushCode()
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushLists()
                inCodeBlock = true
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLanguage = language.isEmpty ? nil : language
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushLists()
                continue
            }

            if trimmed.hasPrefix("## ") {
                flushParagraph()
                flushLists()
                blocks.append(.heading(2, String(trimmed.dropFirst(3))))
                continue
            }

            if trimmed.hasPrefix("### ") {
                flushParagraph()
                flushLists()
                blocks.append(.heading(3, String(trimmed.dropFirst(4))))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                ordered.removeAll(keepingCapacity: true)
                unordered.append(String(trimmed.dropFirst(2)))
                continue
            }

            if let dot = trimmed.firstIndex(of: "."),
               let number = Int(trimmed[..<dot]),
               trimmed.index(after: dot) < trimmed.endIndex,
               trimmed[trimmed.index(after: dot)] == " "
            {
                flushParagraph()
                unordered.removeAll(keepingCapacity: true)
                let text = String(trimmed[trimmed.index(dot, offsetBy: 2)...])
                ordered.append(MarkdownOrderedItem(number: number, text: text))
                continue
            }

            flushLists()
            paragraph.append(trimmed)
        }

        flushParagraph()
        flushLists()
        if inCodeBlock {
            flushCode()
        }

        return blocks
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var isExpanded = false
    @State private var copied = false

    private let collapsedLineCount = 12

    private var lines: [String] {
        code.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private var isLong: Bool {
        lines.count > collapsedLineCount
    }

    private var visibleCode: String {
        if isLong, !isExpanded {
            return lines.prefix(collapsedLineCount).joined(separator: "\n")
        }
        return code
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language?.isEmpty == false ? language! : "text"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if isLong {
                    Button(isExpanded ? "Collapse" : "Expand") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(copied ? Color.green : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()
                .overlay(Color.white.opacity(0.12))

            ScrollView(.horizontal) {
                Text(visibleCode)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }

            if isLong, !isExpanded {
                Text("+\(lines.count - collapsedLineCount) more lines")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}

private struct ToolCallView: View {
    let part: OCMessagePart

    @State private var expanded = false
    @State private var argsExpanded = true
    @State private var resultExpanded = true

    private var payload: ToolPayload {
        ToolPayload(part: part)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let args = payload.arguments {
                    DisclosureGroup("Arguments", isExpanded: $argsExpanded) {
                        ToolTextView(text: args, style: .plain)
                            .padding(.top, 6)
                    }
                    .font(.caption)
                }

                if let result = payload.result {
                    DisclosureGroup("Result", isExpanded: $resultExpanded) {
                        switch payload.style {
                        case .diff:
                            ToolDiffView(text: result)
                        case .terminal:
                            ToolTextView(text: result, style: .terminal)
                        case .plain:
                            ToolTextView(text: result, style: .plain)
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "hammer")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(payload.name)
                    .font(.caption.weight(.semibold))

                Spacer(minLength: 8)

                if let status = payload.status {
                    ToolStatusBadge(status: status)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private enum ToolOutputStyle {
    case diff
    case terminal
    case plain
}

private struct ToolPayload {
    let name: String
    let status: String?
    let arguments: String?
    let result: String?
    let style: ToolOutputStyle

    init(part: OCMessagePart) {
        let raw = part.raw
        name = ToolPayload.string(in: raw, keys: ["tool", "toolName", "name"]) ?? part.type
        status = ToolPayload.string(in: raw, keys: ["status", "state", "phase"]) ?? ToolPayload.bool(in: raw, key: "success").map { $0 ? "success" : "failed" }
        arguments = ToolPayload.section(in: raw, keys: ["input", "args", "arguments", "params", "command"])
        result = ToolPayload.section(in: raw, keys: ["output", "result", "response", "diff", "patch", "stdout", "stderr"]) ?? part.text

        if let result, ToolPayload.looksLikeDiff(result) {
            style = .diff
        } else if ["bash", "shell", "terminal", "zsh"].contains(where: name.lowercased().contains) {
            style = .terminal
        } else if raw.keys.contains(where: { ["stdout", "stderr", "exitcode", "exit_code"].contains($0.lowercased()) }) {
            style = .terminal
        } else {
            style = .plain
        }
    }

    private static func string(in raw: [String: OCJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = raw[key]?.stringValue, !value.isEmpty {
                return value
            }
            if let value = raw.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value.stringValue, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func bool(in raw: [String: OCJSONValue], key: String) -> Bool? {
        if let exact = raw[key], case let .bool(value) = exact {
            return value
        }
        if let match = raw.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value,
           case let .bool(value) = match
        {
            return value
        }
        return nil
    }

    private static func section(in raw: [String: OCJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let exact = raw[key] {
                return exact.stringValue ?? chatFormattedJSON(exact)
            }
            if let match = raw.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
                return match.stringValue ?? chatFormattedJSON(match)
            }
        }
        return nil
    }

    private static func looksLikeDiff(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let hasAdd = lines.contains { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
        let hasRemove = lines.contains { $0.hasPrefix("-") && !$0.hasPrefix("---") }
        return hasAdd && hasRemove
    }
}

private struct ToolStatusBadge: View {
    let status: String

    private var foreground: Color {
        let lowered = status.lowercased()
        if lowered.contains("success") || lowered.contains("ok") {
            return .green
        }
        if lowered.contains("error") || lowered.contains("fail") {
            return .red
        }
        return .secondary
    }

    var body: some View {
        Text(status)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(foreground.opacity(0.14), in: Capsule())
    }
}

private struct ToolTextView: View {
    let text: String
    let style: ToolOutputStyle

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(style == .terminal ? Color.white.opacity(0.92) : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 220)
        .background(style == .terminal ? Color.black.opacity(0.62) : Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        )
    }
}

private struct ToolDiffView: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    let line = lines[index]
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(foreground(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .background(background(for: line))
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxHeight: 220)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        )
    }

    private var lines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func foreground(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return Color.green.opacity(0.95)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return Color.red.opacity(0.95)
        }
        return Color.primary.opacity(0.9)
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return Color.green.opacity(0.12)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return Color.red.opacity(0.12)
        }
        return .clear
    }
}

private extension OCMessagePart {
    var isToolPart: Bool {
        if type.localizedCaseInsensitiveContains("tool") {
            return true
        }
        return raw.keys.contains { $0.localizedCaseInsensitiveContains("tool") }
    }
}

private func chatFormattedJSON(_ value: OCJSONValue) -> String? {
    chatFormattedJSON(value.foundationValue)
}

private func chatFormattedJSON(_ object: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(object) else {
        return nil
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

private extension OCJSONValue {
    var foundationValue: Any {
        switch self {
        case let .string(value):
            value
        case let .number(value):
            value
        case let .bool(value):
            value
        case let .object(value):
            value.mapValues(\.foundationValue)
        case let .array(value):
            value.map(\.foundationValue)
        case .null:
            NSNull()
        }
    }
}

private extension Dictionary where Key == String, Value == OCJSONValue {
    var foundationValue: [String: Any] {
        mapValues(\.foundationValue)
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
