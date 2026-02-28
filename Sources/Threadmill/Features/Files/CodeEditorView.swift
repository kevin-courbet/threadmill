import AppKit
import SwiftUI

struct CodeEditorView: NSViewRepresentable {
    let text: String
    let language: CodeLanguage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = SyntaxHighlighter.Theme.background
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.backgroundColor = SyntaxHighlighter.Theme.background
        textView.textColor = SyntaxHighlighter.Theme.defaultText
        textView.font = SyntaxHighlighter.Theme.font
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.drawsBackground = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        if let textContainer = textView.textContainer {
            textContainer.lineFragmentPadding = 0
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textContainer.widthTracksTextView = false
        }
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true

        let gutter = LineNumberGutter(textView: textView)
        scrollView.verticalRulerView = gutter

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        let languageKey = String(describing: language)
        if context.coordinator.lastText == text, context.coordinator.lastLanguageKey == languageKey {
            return
        }

        let selectedRanges = textView.selectedRanges
        textView.textStorage?.setAttributedString(SyntaxHighlighter.highlight(text, language: language))
        textView.selectedRanges = selectedRanges

        context.coordinator.lastText = text
        context.coordinator.lastLanguageKey = languageKey

        if let gutter = scrollView.verticalRulerView as? LineNumberGutter {
            gutter.invalidateLineNumbers()
        }
    }

    final class Coordinator {
        var lastText: String = ""
        var lastLanguageKey: String = ""
    }
}
