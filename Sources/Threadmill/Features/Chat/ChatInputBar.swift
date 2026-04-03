import ACPModel
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
        let _ = Logger.chat.info("ChatInputBar render — isInputEnabled=\(viewModel.isInputEnabled, privacy: .public), isStreaming=\(viewModel.isStreaming, privacy: .public), canSend=\(canSend, privacy: .public), textLength=\(text.count, privacy: .public)")
        VStack(spacing: 0) {
            // Text input area
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Ask about this thread...")
                        .font(.system(size: ChatTokens.bodyFontSize))
                        .foregroundStyle(ChatTokens.textFaint)
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
            .disabled(!viewModel.isInputEnabled)

            // Bottom row: meta bar dropdowns + send/stop
            HStack(spacing: ChatTokens.metaBarGap) {
                metaBar

                Spacer(minLength: 0)

                sendStopButton
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, ChatTokens.composerPaddingH)
        .padding(.vertical, ChatTokens.composerPaddingV)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ChatTokens.radiusComposer, style: .continuous))
        .overlay {
            AnimatedGradientBorder(style: inputBorderStyle, cornerRadius: ChatTokens.radiusComposer, lineWidth: 1.2, isFocused: isEditorFocused)
                .allowsHitTesting(false)
        }
        .background {
            Button("") {
                Task { await viewModel.cycleModeForward() }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .hidden()
        }
    }

    // MARK: - Meta Bar (dropdowns row)

    private var metaBar: some View {
        HStack(spacing: 6) {
            modelDropdown
            modeDropdown
            effortDropdown
            accessDropdown

            if viewModel.contextWindowSize > 0 {
                ContextRingView(
                    usedTokens: viewModel.contextUsedTokens,
                    windowSize: viewModel.contextWindowSize
                )
            }
        }
    }

    // MARK: - Model Dropdown

    private var modelDropdown: some View {
        MetaBarDropdown(
            icon: "cpu",
            label: "Model",
            options: viewModel.availableModels.map { ($0.modelId, $0.name) },
            selection: viewModel.currentModelID ?? viewModel.availableModels.first?.modelId,
            disabled: viewModel.isStreaming
        ) { modelID in
            Task { await viewModel.setModel(modelID) }
        }
    }

    // MARK: - Mode Dropdown (build, plan, prometheus, sisyphus, etc.)

    private var modeDropdown: some View {
        Group {
            if !viewModel.availableModes.isEmpty {
                MetaBarDropdown(
                    icon: "gearshape.2",
                    label: "Mode",
                    options: viewModel.availableModes.map { ($0.id, $0.name.capitalized) },
                    selection: viewModel.currentMode ?? viewModel.availableModes.first?.id,
                    disabled: viewModel.isStreaming
                ) { modeID in
                    Task { await viewModel.setMode(modeID) }
                }
            }
        }
    }

    // MARK: - Effort Dropdown

    private static let defaultEffortOptions: [(id: String, name: String)] = [
        ("low", "Low"),
        ("medium", "Medium"),
        ("high", "High"),
    ]

    private var effortDropdown: some View {
        let effortOption = viewModel.configOptions.first { $0.id.value == "effort" || $0.id.value == "reasoning_effort" }
        let key = effortOption?.id.value ?? "effort"

        // Use agent-provided options when available, otherwise show defaults
        let options: [(id: String, name: String)] = {
            guard let effortOption, case let .select(select) = effortOption.kind else {
                return Self.defaultEffortOptions
            }
            switch select.options {
            case let .ungrouped(opts): return opts.map { ($0.value.value, $0.name) }
            case let .grouped(groups): return groups.flatMap(\.options).map { ($0.value.value, $0.name) }
            }
        }()

        let currentValue: String = {
            if let stored = viewModel.configOptionValues[key] {
                return stored
            }
            if let effortOption, case let .select(select) = effortOption.kind {
                return select.currentValue.value
            }
            return "high"
        }()

        return MetaBarDropdown(
            icon: "gauge.with.dots.needle.33percent",
            label: "Effort",
            options: options,
            selection: currentValue,
            disabled: viewModel.isStreaming
        ) { value in
            Task { await viewModel.setConfigOption(key: key, value: value) }
        }
    }

    // MARK: - Access Dropdown (full access / standard)

    private var accessDropdown: some View {
        let accessOption = viewModel.configOptions.first { $0.id.value == "access" || $0.id.value == "approval_mode" }
        return Group {
            if let accessOption, case let .select(select) = accessOption.kind {
                let key = accessOption.id.value
                let options: [(id: String, name: String)] = {
                    switch select.options {
                    case let .ungrouped(opts): return opts.map { ($0.value.value, $0.name) }
                    case let .grouped(groups): return groups.flatMap(\.options).map { ($0.value.value, $0.name) }
                    }
                }()
                MetaBarDropdown(
                    icon: "lock.shield",
                    label: "Access",
                    options: options,
                    selection: viewModel.configOptionValues[key] ?? select.currentValue.value,
                    disabled: viewModel.isStreaming
                ) { value in
                    Task { await viewModel.setConfigOption(key: key, value: value) }
                }
            }
        }
    }

    // MARK: - Send / Stop Button

    private var sendStopButton: some View {
        Button {
            Logger.chat.info("ChatInputBar send button tapped — isStreaming=\(viewModel.isStreaming, privacy: .public), canSend=\(canSend, privacy: .public), textLength=\(text.count, privacy: .public)")
            if viewModel.isStreaming {
                Task { await viewModel.cancelCurrentPrompt() }
            } else {
                send()
            }
        } label: {
            ZStack {
                if viewModel.isStreaming {
                    // Stop: red-tinted circle with square stop icon
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.12))
                        Circle()
                            .strokeBorder(Color.red.opacity(0.6), lineWidth: 1.5)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.red.opacity(0.9))
                    }
                } else {
                    // Send: accent gradient circle with arrow
                    ZStack {
                        Circle()
                            .fill(canSend ? AnyShapeStyle(ChatTokens.accentGradient) : AnyShapeStyle(ChatTokens.surfaceCardStrong))
                        Circle()
                            .strokeBorder(canSend ? ChatTokens.borderAccent : ChatTokens.borderSubtle, lineWidth: 1)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(canSend ? Color(nsColor: NSColor(red: 0.043, green: 0.059, blue: 0.102, alpha: 1.0)) : ChatTokens.textFaint)
                    }
                }
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isStreaming && !canSend)
        .animation(.easeOut(duration: ChatTokens.durNormal), value: viewModel.isStreaming)
        .animation(.easeOut(duration: ChatTokens.durNormal), value: canSend)
    }

    private func send() {
        guard canSend else {
            Logger.chat.error("ChatInputBar send skipped — canSend=false, trimmedLength=\(text.trimmingCharacters(in: .whitespacesAndNewlines).count, privacy: .public), isStreaming=\(viewModel.isStreaming, privacy: .public), isInputEnabled=\(viewModel.isInputEnabled, privacy: .public)")
            return
        }

        let outgoingText = text
        Logger.chat.error("ChatInputBar send dispatch — outgoingLength=\(outgoingText.count, privacy: .public)")
        text = ""
        Task {
            await viewModel.sendPrompt(text: outgoingText)
        }
    }
}

// MARK: - ExpandingTextView (NSTextView-backed auto-height input)

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
        textView.font = .systemFont(ofSize: ChatTokens.bodyFontSize)
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
