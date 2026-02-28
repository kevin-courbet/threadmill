import AppKit

final class LineNumberGutter: NSRulerView {
    private enum Theme {
        static let background = color(hex: 0x252535)
        static let text = color(hex: 0x6C7086)
        static let divider = color(hex: 0x313244)
        static let font = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        static let rightPadding: CGFloat = 8
        static let minimumWidth: CGFloat = 36

        private static func color(hex: Int) -> NSColor {
            let red = CGFloat((hex >> 16) & 0xFF) / 255
            let green = CGFloat((hex >> 8) & 0xFF) / 255
            let blue = CGFloat(hex & 0xFF) / 255
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
    }

    weak var textView: NSTextView?
    private var observers: [NSObjectProtocol] = []

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        registerObservers(for: textView)
        invalidateLineNumbers()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.background.setFill()
        rect.fill()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return
        }

        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        if glyphRange.length == 0 {
            drawDivider(in: rect)
            return
        }

        var glyphIndex = glyphRange.location
        var lineNumber = lineNumber(atCharacterIndex: layoutManager.characterIndexForGlyph(at: glyphIndex), text: textView.string)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.font,
            .foregroundColor: Theme.text,
        ]

        while glyphIndex < NSMaxRange(glyphRange) {
            var lineGlyphRange = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange, withoutAdditionalLayout: true)
            let lineNumberString = String(lineNumber)
            let lineSize = (lineNumberString as NSString).size(withAttributes: attributes)
            let x = ruleThickness - Theme.rightPadding - lineSize.width
            let y = lineRect.minY + textView.textContainerOrigin.y + (lineRect.height - lineSize.height) / 2
            (lineNumberString as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)

            glyphIndex = NSMaxRange(lineGlyphRange)
            lineNumber += 1
        }

        drawDivider(in: rect)
    }

    func invalidateLineNumbers() {
        updateRuleThickness()
        needsDisplay = true
    }

    private func registerObservers(for textView: NSTextView) {
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(forName: NSText.didChangeNotification, object: textView, queue: nil) { [weak self] _ in
                self?.invalidateLineNumbers()
            }
        )

        if let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            observers.append(
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView, queue: nil) { [weak self] _ in
                    self?.needsDisplay = true
                }
            )
        }
    }

    private func updateRuleThickness() {
        guard let textView else {
            ruleThickness = Theme.minimumWidth
            return
        }

        let lineCount = max(1, textView.string.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        })

        let digits = max(2, String(lineCount).count)
        let sample = String(repeating: "8", count: digits)
        let sampleWidth = (sample as NSString).size(withAttributes: [.font: Theme.font]).width
        ruleThickness = max(Theme.minimumWidth, sampleWidth + Theme.rightPadding * 2)
    }

    private func lineNumber(atCharacterIndex index: Int, text: String) -> Int {
        guard index > 0 else {
            return 1
        }

        let nsText = text as NSString
        let clampedIndex = min(index, nsText.length)
        var line = 1
        var scanIndex = 0

        while scanIndex < clampedIndex {
            let searchRange = NSRange(location: scanIndex, length: clampedIndex - scanIndex)
            let nextBreak = nsText.range(of: "\n", options: [], range: searchRange)
            if nextBreak.location == NSNotFound {
                break
            }
            line += 1
            scanIndex = nextBreak.location + 1
        }

        return line
    }

    private func drawDivider(in rect: NSRect) {
        Theme.divider.setStroke()
        let dividerX = ruleThickness - 0.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: dividerX, y: rect.minY))
        path.line(to: NSPoint(x: dividerX, y: rect.maxY))
        path.lineWidth = 1
        path.stroke()
    }
}
