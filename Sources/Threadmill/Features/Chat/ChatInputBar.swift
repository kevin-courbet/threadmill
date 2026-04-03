import AppKit
import SwiftUI
import os

struct ChatInputBar: View {
    let viewModel: ChatSessionViewModel

    @State private var text = ""
    @State private var measuredHeight: CGFloat = 44
    @State private var isEditorFocused = false

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isStreaming && viewModel.isInputEnabled
    }

    private var editorHeight: CGFloat {
        min(140, max(44, measuredHeight))
    }

    private var isPlanMode: Bool {
        viewModel.currentMode?.lowercased() == "plan"
    }

    private var inputBorderStyle: AnimatedGradientBorderStyle {
        if viewModel.isStreaming {
            return .streaming
        }
        if isPlanMode {
            return .plan
        }
        return .focusedIdle
    }

    var body: some View {
        let inputEnabled = viewModel.isInputEnabled
        let _ = Logger.chat.info("ChatInputBar render — isInputEnabled=\(inputEnabled, privacy: .public), isStreaming=\(viewModel.isStreaming, privacy: .public), canSend=\(canSend, privacy: .public), textLength=\(text.count, privacy: .public)")
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                modelSelector

                if !viewModel.availableModes.isEmpty {
                    modeSelector
                }

                Spacer(minLength: 0)

                Button {
                    Logger.chat.info("ChatInputBar send button tapped — isStreaming=\(viewModel.isStreaming, privacy: .public), canSend=\(canSend, privacy: .public), textLength=\(text.count, privacy: .public)")
                    if viewModel.isStreaming {
                        Task { await viewModel.cancelCurrentPrompt() }
                    } else {
                        send()
                    }
                } label: {
                    Image(systemName: viewModel.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 24, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.isStreaming ? Color.red : (canSend ? Color.accentColor : Color.secondary))
                .disabled(!viewModel.isStreaming && !canSend)
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Ask about this thread...")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }

                ExpandingTextView(
                    text: $text,
                    measuredHeight: $measuredHeight,
                    isFocused: $isEditorFocused,
                    onSubmit: send,
                    onCancel: viewModel.isStreaming ? {
                        Task { await viewModel.cancelCurrentPrompt() }
                    } : nil
                )
                .frame(height: editorHeight)
            }
            .frame(height: editorHeight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            AnimatedGradientBorder(style: inputBorderStyle, cornerRadius: 18, lineWidth: 1.2, isFocused: isEditorFocused)
                .allowsHitTesting(false)
        }
        .background {
            Button("") {
                Task { await viewModel.cycleModeForward() }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .hidden()
        }
        .disabled(!inputEnabled)
    }

    private var modelSelector: some View {
        Menu {
            if viewModel.availableModels.isEmpty {
                Text("No models available")
            } else {
                ForEach(viewModel.availableModels, id: \.modelId) { model in
                    Button(model.name) {
                        Task {
                            await viewModel.setModel(model.modelId)
                        }
                    }
                }
            }
        } label: {
            Text(selectedModelLabel)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(viewModel.availableModels.isEmpty ? .secondary : .primary)
        }
        .menuStyle(.borderlessButton)
        .disabled(viewModel.isStreaming || viewModel.availableModels.isEmpty)
    }

    private var selectedModelLabel: String {
        guard !viewModel.availableModels.isEmpty else {
            return "Model"
        }
        if let currentModelID = viewModel.currentModelID,
           let currentModel = viewModel.availableModels.first(where: { $0.modelId == currentModelID })
        {
            return currentModel.name
        }
        return viewModel.availableModels.first?.name ?? "Model"
    }

    private var modeSelector: some View {
        Picker("Mode", selection: Binding(
            get: { viewModel.currentMode ?? viewModel.availableModes.first?.id ?? "" },
            set: { modeID in
                Task {
                    await viewModel.setMode(modeID)
                }
            }
        )) {
            ForEach(viewModel.availableModes, id: \.id) { mode in
                Text(mode.name).tag(mode.id)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 240)
    }

    private func send() {
        guard canSend else {
            Logger.chat.info("ChatInputBar send skipped — canSend=false, trimmedLength=\(text.trimmingCharacters(in: .whitespacesAndNewlines).count, privacy: .public), isStreaming=\(viewModel.isStreaming, privacy: .public)")
            return
        }

        let outgoingText = text
        Logger.chat.info("ChatInputBar send dispatch — outgoingLength=\(outgoingText.count, privacy: .public), trimmedLength=\(outgoingText.trimmingCharacters(in: .whitespacesAndNewlines).count, privacy: .public)")
        text = ""
        Task {
            await viewModel.sendPrompt(text: outgoingText)
        }
    }
}

private struct ExpandingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onCancel: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? SubmitTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
        }
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        context.coordinator.parentIsFocused = $isFocused
        context.coordinator.recomputeHeight(for: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: ExpandingTextView
        var parentIsFocused: Binding<Bool>?

        init(_ parent: ExpandingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            parent.text = textView.string
            recomputeHeight(for: textView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parentIsFocused?.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parentIsFocused?.wrappedValue = false
        }

        func recomputeHeight(for textView: NSTextView) {
            let measured = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 44
            let nextHeight = min(140, max(44, measured + 16))
            if abs(parent.measuredHeight - nextHeight) > 0.5 {
                parent.measuredHeight = nextHeight
            }
        }
    }
}

private final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Escape: cancel streaming when active
        if event.keyCode == 53 {
            if let onCancel {
                onCancel()
                return
            }
            return
        }

        let isReturn = event.keyCode == 36
        let isShift = event.modifierFlags.contains(.shift)

        if isReturn && !isShift {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return
            }
            onSubmit?()
            return
        }

        if isReturn && isShift {
            insertNewline(nil)
            return
        }

        super.keyDown(with: event)
    }
}
