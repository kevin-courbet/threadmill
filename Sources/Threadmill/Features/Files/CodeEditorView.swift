import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages

struct CodeEditorView: View {
    let content: String
    let language: CodeLanguage
    var isEditable: Bool = false

    @State private var text: String
    @State private var editorState = SourceEditorState()

    @AppStorage("editorFontSize") private var editorFontSize: Double = 12.0
    @AppStorage("editorWrapLines") private var editorWrapLines: Bool = true

    init(content: String, language: CodeLanguage, isEditable: Bool = false) {
        self.content = content
        self.language = language
        self.isEditable = isEditable
        _text = State(initialValue: content)
    }

    var body: some View {
        SourceEditor(
            $text,
            language: language,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: Self.defaultTheme,
                    font: .monospacedSystemFont(ofSize: editorFontSize, weight: .regular),
                    wrapLines: editorWrapLines
                ),
                peripherals: .init(
                    showGutter: true,
                    showMinimap: false
                )
            ),
            state: $editorState
        )
        .disabled(!isEditable)
        .clipped()
        .onChange(of: content) { _, newValue in
            if text != newValue {
                text = newValue
            }
        }
    }

    // Catppuccin Mocha-inspired dark theme
    private static let defaultTheme = EditorTheme(
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
