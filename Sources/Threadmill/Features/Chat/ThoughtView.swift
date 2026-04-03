import SwiftUI

/// Renders agent reasoning/thought chain items.
/// Title = first non-empty line (capped at 80 chars, markdown stripped).
/// Body = remainder, rendered as muted text clamped to 3 lines when collapsed.
struct ThoughtView: View {
    let item: ThoughtTimelineItem
    let isStreaming: Bool

    @State private var isExpanded: Bool

    init(item: ThoughtTimelineItem, isStreaming: Bool) {
        self.item = item
        self.isStreaming = isStreaming
        _isExpanded = State(initialValue: isStreaming)
    }

    private var parsed: (title: String, body: String) {
        Self.parseThought(item.text)
    }

    var body: some View {
        let (title, body) = parsed
        let hasBody = !body.isEmpty

        VStack(alignment: .leading, spacing: 6) {
            // Header: brain icon + title + chevron
            Button {
                guard hasBody else { return }
                withAnimation(.easeInOut(duration: ChatTokens.durNormal)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isStreaming ? ChatTokens.statusWarning : ChatTokens.statusSuccess)

                    Text(title)
                        .font(.system(size: ChatTokens.captionFontSize, weight: .semibold))
                        .foregroundStyle(ChatTokens.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if hasBody {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(ChatTokens.textFaint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Body: muted smaller text, clamped to 3 lines when collapsed
            if hasBody {
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(ChatTokens.textMuted)
                    .lineSpacing(3)
                    .lineLimit(isExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.leading, 20)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .toolCallCard()
        .onChange(of: isStreaming) { _, streaming in
            withAnimation(.easeInOut(duration: ChatTokens.durNormal)) {
                isExpanded = streaming
            }
        }
    }

    // MARK: - Parsing

    /// Splits thought text into title (first non-empty line, cleaned, capped) and body (rest).
    private static func parseThought(_ text: String) -> (title: String, body: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }

        guard let titleIndex = trimmedLines.firstIndex(where: { !$0.isEmpty }) else {
            return ("Reasoning", "")
        }

        let rawTitle = trimmedLines[titleIndex]
        let cleanTitle = sanitizeTitle(rawTitle)
        let title = cleanTitle.count > 80 ? String(cleanTitle.prefix(80)) + "\u{2026}" : cleanTitle

        let bodyLines = lines.enumerated()
            .filter { $0.offset != titleIndex }
            .map(\.element)
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return (title.isEmpty ? "Reasoning" : title, body)
    }

    /// Strip markdown emphasis marks and link syntax from the title.
    private static func sanitizeTitle(_ title: String) -> String {
        var s = title
        // Strip backticks, bold/italic markers
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "*", with: "")
        s = s.replacingOccurrences(of: "_", with: "")
        s = s.replacingOccurrences(of: "~", with: "")
        // Strip [text](url) → text
        if let regex = try? NSRegularExpression(pattern: #"\[(.*?)\]\(.*?\)"#) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "$1")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
