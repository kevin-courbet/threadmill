import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var isExpanded = false
    @State private var copied = false

    private let collapseThreshold = 12
    private let previewLines = 8

    private var allLines: [String] {
        code.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private var isCollapsible: Bool {
        allLines.count >= collapseThreshold
    }

    private var displayCode: String {
        if isCollapsible, !isExpanded {
            return allLines.prefix(previewLines).joined(separator: "\n")
        }
        return code
    }

    private var displayLineCount: Int {
        max(1, displayCode.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    private var languageLabel: String {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed! : "text").lowercased()
    }

    private var codeLanguage: CodeLanguage {
        LanguageDetection.codeLanguageFromString(languageLabel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon(for: languageLabel))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)

                Text(languageLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text("\(allLines.count) lines")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(copied ? Color.green : .secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)

                if isCollapsible {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            SourceEditorSnippet(code: displayCode, language: codeLanguage)
                .id(isExpanded)
                .frame(
                    height: min(
                        CGFloat(displayLineCount) * 18 + 8,
                        isCollapsible && !isExpanded ? 220 : 360
                    )
                )
                .clipped()

            if isCollapsible, !isExpanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isExpanded = true
                    }
                } label: {
                    Text("Show \(allLines.count - previewLines) more lines")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(red: 0.12, green: 0.12, blue: 0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
        )

    }

    private func icon(for language: String) -> String {
        switch language {
        case "swift": "swift"
        case "python", "py": "text.page"
        case "javascript", "typescript", "js", "ts", "tsx", "jsx": "curlybraces"
        case "bash", "sh", "zsh", "shell": "terminal"
        case "json", "yaml", "yml", "toml": "doc.text"
        case "rust", "rs": "gearshape.2"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }
}

private struct SourceEditorSnippet: View {
    let code: String
    let language: CodeLanguage

    @State private var text: String
    @State private var editorState = SourceEditorState()

    init(code: String, language: CodeLanguage) {
        self.code = code
        self.language = language
        _text = State(initialValue: code)
    }

    var body: some View {
        SourceEditor(
            $text,
            language: language,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: Self.theme,
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    wrapLines: false
                ),
                behavior: .init(isEditable: false),
                peripherals: .init(showGutter: true, showMinimap: false)
            ),
            state: $editorState
        )
        .onChange(of: code) { _, newValue in
            if text != newValue {
                text = newValue
            }
        }
    }

    private static let theme = EditorTheme(
        text: .init(color: NSColor(red: 0.80, green: 0.84, blue: 0.96, alpha: 1.0)),
        insertionPoint: NSColor(red: 0.80, green: 0.84, blue: 0.96, alpha: 1.0),
        invisibles: .init(color: .systemGray),
        background: NSColor(red: 0.12, green: 0.12, blue: 0.18, alpha: 1.0),
        lineHighlight: NSColor(red: 0.18, green: 0.19, blue: 0.26, alpha: 1.0),
        selection: .selectedTextBackgroundColor,
        keywords: .init(color: NSColor(red: 0.80, green: 0.64, blue: 0.96, alpha: 1.0)),
        commands: .init(color: NSColor(red: 0.54, green: 0.71, blue: 0.98, alpha: 1.0)),
        types: .init(color: NSColor(red: 0.95, green: 0.80, blue: 0.55, alpha: 1.0)),
        attributes: .init(color: NSColor(red: 0.95, green: 0.55, blue: 0.66, alpha: 1.0)),
        variables: .init(color: NSColor(red: 0.54, green: 0.71, blue: 0.98, alpha: 1.0)),
        values: .init(color: NSColor(red: 0.98, green: 0.63, blue: 0.44, alpha: 1.0)),
        numbers: .init(color: NSColor(red: 0.98, green: 0.63, blue: 0.44, alpha: 1.0)),
        strings: .init(color: NSColor(red: 0.65, green: 0.89, blue: 0.63, alpha: 1.0)),
        characters: .init(color: NSColor(red: 0.65, green: 0.89, blue: 0.63, alpha: 1.0)),
        comments: .init(color: NSColor(red: 0.45, green: 0.48, blue: 0.58, alpha: 1.0))
    )
}
