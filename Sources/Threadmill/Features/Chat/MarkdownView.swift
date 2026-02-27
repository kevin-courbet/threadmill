import SwiftUI

struct MarkdownView: View {
    let text: String

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(text)
    }

    private var groupedBlocks: [MarkdownBlock] {
        var values: [MarkdownBlock] = []

        for block in blocks {
            if case let .paragraph(newText) = block,
               case let .paragraph(existingText)? = values.last
            {
                values[values.count - 1] = .paragraph(existingText + "\n\n" + newText)
                continue
            }

            values.append(block)
        }

        return values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groupedBlocks.indices, id: \.self) { index in
                blockView(groupedBlocks[index])
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, content):
            InlineRunsView(
                runs: InlineParser.parse(content),
                fontSize: 15 * headingScale(for: level),
                weight: .semibold,
                lineSpacing: 5
            )

        case let .paragraph(content):
            InlineRunsView(
                runs: InlineParser.parse(content),
                fontSize: 14,
                weight: .regular,
                lineSpacing: 4
            )

        case let .unordered(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 1)

                        InlineRunsView(
                            runs: InlineParser.parse(items[index]),
                            fontSize: 14,
                            weight: .regular,
                            lineSpacing: 4
                        )
                    }
                }
            }

        case let .ordered(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(item.number).")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                            .padding(.top, 1)

                        InlineRunsView(
                            runs: InlineParser.parse(item.text),
                            fontSize: 14,
                            weight: .regular,
                            lineSpacing: 4
                        )
                    }
                }
            }

        case let .blockquote(content):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.primary.opacity(0.2))
                    .frame(width: 3)

                InlineRunsView(
                    runs: InlineParser.parse(content),
                    fontSize: 13,
                    weight: .regular,
                    lineSpacing: 4,
                    foreground: Color.secondary
                )
            }
            .padding(.vertical, 2)

        case let .code(language, code):
            CodeBlockView(code: code, language: language)
        }
    }

    private func headingScale(for level: Int) -> CGFloat {
        switch level {
        case 1: 1.5
        case 2: 1.3
        case 3: 1.15
        default: 1.05
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
}

private enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var unordered: [String] = []
        var ordered: [MarkdownOrderedItem] = []
        var quote: [String] = []
        var code: [String] = []
        var codeLanguage: String?
        var inCodeBlock = false

        func flushParagraph() {
            guard !paragraph.isEmpty else {
                return
            }
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
            guard !quote.isEmpty else {
                return
            }
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

        return blocks
    }

    private static func parseHeading(_ text: String) -> (level: Int, text: String)? {
        let hashes = text.prefix { $0 == "#" }
        guard (1 ... 4).contains(hashes.count) else {
            return nil
        }
        let content = text.dropFirst(hashes.count)
        guard content.first == " " else {
            return nil
        }
        return (hashes.count, String(content.dropFirst()))
    }

    private static func parseQuote(_ text: String) -> String? {
        guard text.hasPrefix(">") else {
            return nil
        }
        let content = text.dropFirst()
        if content.first == " " {
            return String(content.dropFirst())
        }
        return String(content)
    }

    private static func parseBullet(_ text: String) -> String? {
        guard text.count > 2 else {
            return nil
        }
        if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ") {
            return String(text.dropFirst(2))
        }
        return nil
    }

    private static func parseOrdered(_ text: String) -> MarkdownOrderedItem? {
        guard let dot = text.firstIndex(of: "."),
              let number = Int(text[..<dot])
        else {
            return nil
        }

        let afterDot = text.index(after: dot)
        guard afterDot < text.endIndex, text[afterDot] == " " else {
            return nil
        }

        let contentStart = text.index(after: afterDot)
        guard contentStart <= text.endIndex else {
            return nil
        }

        return MarkdownOrderedItem(number: number, text: String(text[contentStart...]))
    }
}

private struct InlineRunsView: View {
    let runs: [InlineRun]
    let fontSize: CGFloat
    let weight: Font.Weight
    let lineSpacing: CGFloat
    var foreground: Color = .primary

    var body: some View {
        InlineWrapLayout(lineSpacing: lineSpacing) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                runView(run)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func runView(_ run: InlineRun) -> some View {
        if let url = run.link {
            Link(destination: url) {
                textView(for: run)
                    .foregroundStyle(.blue)
                    .underline()
            }
            .buttonStyle(.plain)
        } else {
            textView(for: run)
        }
    }

    @ViewBuilder
    private func textView(for run: InlineRun) -> some View {
        if run.styles.contains(.code) {
            Text(run.text)
                .font(.system(size: max(12, fontSize * 0.92), weight: .regular, design: .monospaced))
                .foregroundStyle(foreground.opacity(0.95))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Text(run.text)
                .font(.system(size: fontSize, weight: resolvedWeight(for: run), design: .default))
                .italic(run.styles.contains(.italic))
                .foregroundStyle(foreground)
        }
    }

    private func resolvedWeight(for run: InlineRun) -> Font.Weight {
        run.styles.contains(.bold) ? .semibold : weight
    }
}

private struct InlineWrapLayout: Layout {
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))

            if lineWidth > 0, lineWidth + size.width > maxWidth {
                width = max(width, lineWidth)
                height += lineHeight + lineSpacing
                lineWidth = 0
                lineHeight = 0
            }

            lineWidth += size.width
            lineHeight = max(lineHeight, size.height)
        }

        width = max(width, lineWidth)
        height += lineHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))

            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            x += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private enum InlineStyle: Hashable {
    case bold
    case italic
    case code
}

private struct InlineRun {
    let text: String
    let styles: Set<InlineStyle>
    let link: URL?
}

private enum InlineParser {
    static func parse(_ source: String, inherited: Set<InlineStyle> = []) -> [InlineRun] {
        var runs: [InlineRun] = []
        var buffer = ""
        var index = source.startIndex

        func flushBuffer() {
            guard !buffer.isEmpty else {
                return
            }
            runs.append(InlineRun(text: buffer, styles: inherited, link: nil))
            buffer.removeAll(keepingCapacity: true)
        }

        while index < source.endIndex {
            if source[index] == "`",
               let close = source[source.index(after: index)...].firstIndex(of: "`")
            {
                flushBuffer()
                let content = String(source[source.index(after: index) ..< close])
                runs.append(InlineRun(text: content, styles: inherited.union([.code]), link: nil))
                index = source.index(after: close)
                continue
            }

            if source[index] == "[",
               let endLabel = source[source.index(after: index)...].firstIndex(of: "]")
            {
                let openParen = source.index(after: endLabel)
                if openParen < source.endIndex,
                   source[openParen] == "(",
                   let closeParen = source[source.index(after: openParen)...].firstIndex(of: ")")
                {
                    let label = String(source[source.index(after: index) ..< endLabel])
                    let destination = String(source[source.index(after: openParen) ..< closeParen])
                    if let url = URL(string: destination), !label.isEmpty {
                        flushBuffer()
                        let labelRuns = parse(label, inherited: inherited)
                        for run in labelRuns {
                            runs.append(InlineRun(text: run.text, styles: run.styles, link: url))
                        }
                        index = source.index(after: closeParen)
                        continue
                    }
                }
            }

            if source.hasPrefix("**", at: index) {
                let start = source.index(index, offsetBy: 2)
                if let close = source.range(of: "**", range: start ..< source.endIndex)?.lowerBound {
                    flushBuffer()
                    let content = String(source[start ..< close])
                    runs.append(contentsOf: parse(content, inherited: inherited.union([.bold])))
                    index = source.index(close, offsetBy: 2)
                    continue
                }
            }

            if source[index] == "*" {
                let start = source.index(after: index)
                if let close = source[start...].firstIndex(of: "*") {
                    flushBuffer()
                    let content = String(source[start ..< close])
                    runs.append(contentsOf: parse(content, inherited: inherited.union([.italic])))
                    index = source.index(after: close)
                    continue
                }
            }

            buffer.append(source[index])
            index = source.index(after: index)
        }

        flushBuffer()
        return mergedRuns(runs)
    }

    private static func mergedRuns(_ runs: [InlineRun]) -> [InlineRun] {
        var values: [InlineRun] = []

        for run in runs {
            guard let last = values.last else {
                values.append(run)
                continue
            }

            if last.styles == run.styles, last.link == run.link {
                values[values.count - 1] = InlineRun(text: last.text + run.text, styles: run.styles, link: run.link)
            } else {
                values.append(run)
            }
        }

        return values
    }
}

private extension String {
    func hasPrefix(_ prefix: String, at index: Index) -> Bool {
        guard let end = self.index(index, offsetBy: prefix.count, limitedBy: endIndex) else {
            return false
        }
        return self[index ..< end] == prefix
    }
}

private extension View {
    @ViewBuilder
    func italic(_ enabled: Bool) -> some View {
        if enabled {
            self.italic()
        } else {
            self
        }
    }
}
