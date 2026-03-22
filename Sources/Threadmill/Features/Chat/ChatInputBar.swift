import AppKit
import SwiftUI

struct ChatInputBar: View {
    let viewModel: ChatSessionViewModel

    @State private var text = ""
    @State private var measuredHeight: CGFloat = 44

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isStreaming
    }

    private var editorHeight: CGFloat {
        min(140, max(44, measuredHeight))
    }

    private var borderState: AnimatedGradientBorderState {
        if viewModel.isStreaming {
            return .streaming
        }
        if viewModel.currentMode?.lowercased() == "plan" {
            return .plan
        }
        return .idleFocused
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                agentSelector
                modelSelector

                if !viewModel.availableModes.isEmpty {
                    modeSelector
                }

                Spacer(minLength: 0)

                Button {
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
                    onSubmit: send
                )
                .frame(height: editorHeight)
            }
            .frame(height: editorHeight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            AnimatedGradientBorder(
                state: borderState,
                cornerRadius: 18,
                lineWidth: viewModel.isStreaming ? 1.7 : 1.0
            )
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

    private var agentSelector: some View {
        Menu {
            ForEach(viewModel.availableAgents) { agent in
                Button(agent.displayName) {
                    Task {
                        await viewModel.selectAgent(named: agent.name)
                    }
                }
            }
        } label: {
            Text(AgentConfig.displayName(for: viewModel.selectedAgentName))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .disabled(viewModel.isStreaming)
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
            return
        }

        let outgoingText = text
        text = ""
        Task {
            await viewModel.sendPrompt(text: outgoingText)
        }
    }
}

private struct ExpandingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let onSubmit: () -> Void

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
        context.coordinator.recomputeHeight(for: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: ExpandingTextView

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

    override func keyDown(with event: NSEvent) {
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
