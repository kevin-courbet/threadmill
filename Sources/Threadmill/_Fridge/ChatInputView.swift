import SwiftUI
import AppKit

// MARK: - NSTextView wrapper: Enter sends, Shift+Enter inserts newline

struct ChatTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var isFocused: Binding<Bool>?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier("chat.input.text")

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmitTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.onSubmit = onSubmit
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ChatTextEditor
        init(_ parent: ChatTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused?.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused?.wrappedValue = false
        }
    }
}

/// NSTextView subclass that sends on Enter and inserts newline on Shift+Enter
private class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 // Return key
        let isShift = event.modifierFlags.contains(.shift)

        if isReturn && !isShift {
            // Enter without shift → submit
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onSubmit?()
            return
        }

        if isReturn && isShift {
            // Shift+Enter → insert newline
            insertNewline(nil)
            return
        }

        super.keyDown(with: event)
    }
}

// MARK: - ChatInputView

struct ChatInputView: View {
    @Binding var text: String
    let isGenerating: Bool
    let onSend: () -> Void
    let onAbort: () -> Void

    @State private var inputFocused: Bool = false
    @State private var measuredEditorHeight: CGFloat = 44

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    private var editorHeight: CGFloat {
        min(140, max(44, measuredEditorHeight))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)

                if isGenerating {
                    Button {
                        onAbort()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.input.abort")
                } else {
                    Button {
                        onSend()
                    } label: {
                        Label("Send", systemImage: "arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(canSend ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityIdentifier("chat.input.send")
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Ask about this thread...")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }

                    ChatTextEditor(
                        text: $text,
                        onSubmit: { if canSend { onSend() } },
                        isFocused: $inputFocused
                    )
                    .frame(height: editorHeight)

                    Text(measurementText)
                        .font(.body)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 9)
                        .frame(width: max(0, geometry.size.width - 8), alignment: .leading)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: ChatInputHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        )
                        .hidden()
                        .allowsHitTesting(false)
                }
            }
            .frame(height: editorHeight)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        inputFocused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.3),
                        lineWidth: inputFocused ? 1 : 0.5
                    )
                    .animation(.easeInOut(duration: 0.18), value: inputFocused)
            )
            .onPreferenceChange(ChatInputHeightPreferenceKey.self) { height in
                measuredEditorHeight = height
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 0.5)
        )
    }

    private var measurementText: String {
        let value = text.isEmpty ? " " : text
        return value + "\n"
    }
}

private struct ChatInputHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 44

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
