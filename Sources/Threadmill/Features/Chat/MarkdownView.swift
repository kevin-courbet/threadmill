import AppKit
import Foundation
import SwiftUI

struct MarkdownView: View {
    let text: String
    var isStreaming: Bool = false

    @StateObject private var viewModel = MarkdownViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groupBlocks(viewModel.blocks)) { group in
                switch group {
                case let .text(id, blocks):
                    CombinedTextBlockView(id: id, blocks: blocks)
                case let .special(_, block):
                    specialBlockView(block)
                }
            }

            if isStreaming, !viewModel.streamingBuffer.isEmpty {
                StreamingTextView(text: viewModel.streamingBuffer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            viewModel.parse(text: text, isStreaming: isStreaming)
        }
        .onChange(of: text) { _, newValue in
            viewModel.parse(text: newValue, isStreaming: isStreaming)
        }
        .onChange(of: isStreaming) { _, newValue in
            viewModel.parse(text: text, isStreaming: newValue)
        }
    }

    @ViewBuilder
    private func specialBlockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .unordered(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        MarkdownInlineText(text: item)
                    }
                }
            }
        case let .ordered(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(items[index].number).")
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                        MarkdownInlineText(text: items[index].text)
                    }
                }
            }
        case let .blockquote(content):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                MarkdownInlineText(text: content)
                    .foregroundStyle(.secondary)
            }
        case let .code(language, code):
            CodeBlockView(code: code, language: language)
        case .heading, .paragraph:
            EmptyView()
        }
    }

    private func groupBlocks(_ blocks: [MarkdownBlock]) -> [MarkdownBlockGroup] {
        var result: [MarkdownBlockGroup] = []
        var textBuffer: [MarkdownBlock] = []

        func flushTextBuffer() {
            guard !textBuffer.isEmpty else {
                return
            }
            let id = textBuffer.map(\.id).joined(separator: ":")
            result.append(.text(id: id, blocks: textBuffer))
            textBuffer.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            switch block {
            case .heading, .paragraph:
                textBuffer.append(block)
            case .unordered, .ordered, .blockquote, .code:
                flushTextBuffer()
                result.append(.special(id: block.id, block: block))
            }
        }

        flushTextBuffer()
        return result
    }
}

private enum MarkdownBlockGroup: Identifiable {
    case text(id: String, blocks: [MarkdownBlock])
    case special(id: String, block: MarkdownBlock)

    var id: String {
        switch self {
        case let .text(id, _):
            return "text:\(id)"
        case let .special(id, _):
            return "special:\(id)"
        }
    }
}

private struct MarkdownInlineText: View {
    let text: String

    var body: some View {
        Text(attributed)
            .font(.system(size: 14))
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

private struct CombinedTextBlockView: NSViewRepresentable {
    let id: String
    let blocks: [MarkdownBlock]

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        nsView.textStorage?.setAttributedString(buildAttributedText())
    }

    private func buildAttributedText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }
            switch block {
            case let .heading(level, text):
                let attributed = (try? AttributedString(markdown: text)) ?? AttributedString(text)
                let ns = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
                let fontSize: CGFloat
                switch level {
                case 1: fontSize = 22
                case 2: fontSize = 19
                case 3: fontSize = 17
                default: fontSize = 15
                }
                ns.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize, weight: .semibold), range: NSRange(location: 0, length: ns.length))
                result.append(ns)
            case let .paragraph(text):
                let attributed = (try? AttributedString(markdown: text)) ?? AttributedString(text)
                result.append(NSAttributedString(attributed))
            case .unordered, .ordered, .blockquote, .code:
                break
            }
        }
        return result
    }
}

private struct StreamingTextView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
    }
}

@MainActor
private final class MarkdownViewModel: ObservableObject {
    @Published var blocks: [MarkdownBlock] = []
    @Published var streamingBuffer = ""

    private var parseTask: Task<Void, Never>?

    func parse(text: String, isStreaming: Bool) {
        parseTask?.cancel()
        parseTask = Task.detached(priority: .userInitiated) {
            let parsed = MarkdownParser.parse(text, isStreaming: isStreaming)
            await MainActor.run {
                self.blocks = parsed.blocks
                self.streamingBuffer = parsed.streamingBuffer
            }
        }
    }
}

private struct MarkdownOrderedItem: Equatable {
    let number: Int
    let text: String
}

private enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case unordered([String])
    case ordered([MarkdownOrderedItem])
    case blockquote(String)
    case code(String?, String)

    var id: String {
        switch self {
        case let .heading(level, text):
            return "h\(level):\(text.hashValue)"
        case let .paragraph(text):
            return "p:\(text.hashValue)"
        case let .unordered(items):
            return "u:\(items.joined(separator: "|").hashValue)"
        case let .ordered(items):
            return "o:\(items.map(\.text).joined(separator: "|").hashValue)"
        case let .blockquote(text):
            return "q:\(text.hashValue)"
        case let .code(language, text):
            return "c:\(language ?? "none"):\(text.hashValue)"
        }
    }
}

private enum MarkdownParser {
    struct ParseResult {
        let blocks: [MarkdownBlock]
        let streamingBuffer: String
    }

    static func parse(_ source: String, isStreaming: Bool) -> ParseResult {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let fullText: String
        let streamingBuffer: String
        if isStreaming,
           !normalized.hasSuffix("\n"),
           let lastBreak = normalized.lastIndex(of: "\n")
        {
            fullText = String(normalized[..<lastBreak])
            streamingBuffer = String(normalized[normalized.index(after: lastBreak)...])
        } else {
            fullText = normalized
            streamingBuffer = ""
        }

        let lines = fullText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var unordered: [String] = []
        var ordered: [MarkdownOrderedItem] = []
        var quote: [String] = []
        var code: [String] = []
        var codeLanguage: String?
        var inCodeBlock = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
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

        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.blockquote(quote.joined(separator: "\n")))
            quote.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            blocks.append(.code(codeLanguage, code.joined(separator: "\n")))
            code.removeAll(keepingCapacity: true)
            codeLanguage = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inCodeBlock {
                if trimmed.hasPrefix("```") {
                    inCodeBlock = false
                    flushCode()
                } else {
                    code.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushLists()
                flushQuote()
                inCodeBlock = true
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLanguage = language.isEmpty ? nil : language
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushLists()
                flushQuote()
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                flushLists()
                flushQuote()
                blocks.append(.heading(heading.level, heading.text))
                continue
            }

            if let quoteLine = parseQuote(trimmed) {
                flushParagraph()
                flushLists()
                quote.append(quoteLine)
                continue
            }

            if let bullet = parseBullet(trimmed) {
                flushParagraph()
                flushQuote()
                if !ordered.isEmpty {
                    flushLists()
                }
                unordered.append(bullet)
                continue
            }

            if let orderedItem = parseOrdered(trimmed) {
                flushParagraph()
                flushQuote()
                if !unordered.isEmpty {
                    flushLists()
                }
                ordered.append(orderedItem)
                continue
            }

            flushLists()
            flushQuote()
            paragraph.append(trimmed)
        }

        flushParagraph()
        flushLists()
        flushQuote()
        if inCodeBlock {
            flushCode()
        }

        return ParseResult(blocks: blocks, streamingBuffer: streamingBuffer)
    }

    private static func parseHeading(_ text: String) -> (level: Int, text: String)? {
        let hashes = text.prefix { $0 == "#" }
        guard (1 ... 4).contains(hashes.count) else { return nil }
        let content = text.dropFirst(hashes.count)
        guard content.first == " " else { return nil }
        return (hashes.count, String(content.dropFirst()))
    }

    private static func parseQuote(_ text: String) -> String? {
        guard text.hasPrefix(">") else { return nil }
        let content = text.dropFirst()
        return content.first == " " ? String(content.dropFirst()) : String(content)
    }

    private static func parseBullet(_ text: String) -> String? {
        if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ") {
            return String(text.dropFirst(2))
        }
        return nil
    }

    private static func parseOrdered(_ text: String) -> MarkdownOrderedItem? {
        guard let dot = text.firstIndex(of: "."), let number = Int(text[..<dot]) else {
            return nil
        }
        let afterDot = text.index(after: dot)
        guard afterDot < text.endIndex, text[afterDot] == " " else {
            return nil
        }
        return MarkdownOrderedItem(number: number, text: String(text[text.index(after: afterDot)...]))
    }
}
