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
            effortDropdown
            modeDropdown
            accessDropdown

            if viewModel.contextWindowSize > 0 {
                ContextRingView(
                    usedTokens: viewModel.contextUsedTokens,
                    windowSize: viewModel.contextWindowSize
                )
            }
        }
    }

    // MARK: - Model + Effort Grouping

    /// Vendor/provider prefixes stripped from display names — everyone knows "Opus" is Claude.
    private static func shortenModelName(_ name: String) -> String {
        var s = name
        // Strip vendor prefixes (case-insensitive, preserving rest of casing)
        let prefixes = [
            "Anthropic ", "anthropic/",
            "Claude ", "claude-",
            "OpenAI ", "openai/",
            "Google ", "google/",
            "Meta ", "meta/", "Meta-", "meta-",
            "Mistral ", "mistral/",
            "DeepSeek ", "deepseek/", "deepseek-",
            "Cohere ", "cohere/",
            "xAI ", "xai/",
        ]
        for prefix in prefixes {
            if s.lowercased().hasPrefix(prefix.lowercased()) {
                s = String(s.dropFirst(prefix.count))
            }
        }
        // Capitalize first letter if it got lowercased
        if let first = s.first, first.isLowercase {
            s = first.uppercased() + s.dropFirst()
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// All known reasoning/effort level suffixes that appear in model IDs or names.
    private static let effortSuffixes = ["minimal", "low", "medium", "high", "xhigh", "max", "auto"]

    /// Parsed model entry: a raw model split into base identity + effort level.
    private struct ParsedModel {
        let modelId: String
        let baseName: String
        let baseKey: String
        let effort: String?
    }

    /// Parse a single ModelInfo into base model + optional effort level.
    private static func parseModel(_ model: ModelInfo) -> ParsedModel {
        let id = model.modelId
        let name = model.name

        // Try to split effort from the ID (e.g. "claude-opus-4-low" → base "claude-opus-4", effort "low")
        for suffix in effortSuffixes {
            // Check ID patterns: "base-suffix" or "base/suffix" or "base:suffix"
            for separator in ["-", "/", ":"] {
                let tail = separator + suffix
                if id.lowercased().hasSuffix(tail) {
                    let baseId = String(id.dropLast(tail.count))
                    // Also strip from name: "Claude Opus 4 (Low)" → "Claude Opus 4"
                    let cleanName = name
                        .replacingOccurrences(of: "(\(suffix))", with: "", options: .caseInsensitive)
                        .replacingOccurrences(of: " \(suffix)", with: "", options: .caseInsensitive)
                        .replacingOccurrences(of: "-\(suffix)", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                        .trimmingCharacters(in: .whitespaces)
                    return ParsedModel(
                        modelId: id,
                        baseName: cleanName.isEmpty ? name : cleanName,
                        baseKey: baseId.lowercased(),
                        effort: suffix
                    )
                }
            }
        }

        return ParsedModel(modelId: id, baseName: name, baseKey: id.lowercased(), effort: nil)
    }

    /// All models parsed and grouped by base key.
    private var parsedModels: [ParsedModel] {
        viewModel.availableModels.map(Self.parseModel)
    }

    /// Unique base models for the model dropdown (stable order, first occurrence wins).
    private var baseModelOptions: [(id: String, name: String)] {
        var seen = Set<String>()
        var result: [(id: String, name: String)] = []
        for pm in parsedModels {
            guard seen.insert(pm.baseKey).inserted else { continue }
            result.append((pm.baseKey, Self.shortenModelName(pm.baseName)))
        }
        return result
    }

    /// The base key of the currently selected model.
    private var currentBaseKey: String? {
        guard let currentID = viewModel.currentModelID ?? viewModel.availableModels.first?.modelId else {
            return nil
        }
        return Self.parseModel(ModelInfo(modelId: currentID, name: "")).baseKey
    }

    /// Human-readable effort level names.
    private static let effortDisplayNames: [String: String] = [
        "minimal": "Minimal",
        "low": "Low",
        "medium": "Medium",
        "high": "High",
        "xhigh": "Extra High",
        "max": "Max",
        "auto": "Auto",
    ]

    /// Effort levels available for the currently selected base model (ordered by intensity).
    private var effortLevelsForCurrentModel: [(id: String, name: String)] {
        guard let baseKey = currentBaseKey else { return [] }
        let available = parsedModels
            .filter { $0.baseKey == baseKey && $0.effort != nil }
            .map { $0.effort! }
        // Preserve canonical ordering
        return Self.effortSuffixes
            .filter { available.contains($0) }
            .map { ($0, Self.effortDisplayNames[$0] ?? $0.capitalized) }
    }

    /// The effort level of the currently selected model (parsed from its ID).
    private var currentEffortFromModel: String? {
        guard let currentID = viewModel.currentModelID else { return nil }
        return Self.parseModel(ModelInfo(modelId: currentID, name: "")).effort
    }

    /// Resolve a (baseKey, effort) pair back to the full model ID.
    private func resolveModelID(baseKey: String, effort: String?) -> String? {
        if let effort {
            // Find exact match with this effort
            if let match = parsedModels.first(where: { $0.baseKey == baseKey && $0.effort == effort }) {
                return match.modelId
            }
        }
        // Fallback: first model with this base key
        return parsedModels.first(where: { $0.baseKey == baseKey })?.modelId
    }

    // MARK: - Model Dropdown (deduplicated, no effort suffixes)

    private var modelDropdown: some View {
        MetaBarDropdown(
            icon: "cpu",
            label: "Model",
            options: baseModelOptions,
            selection: currentBaseKey,
            disabled: viewModel.isStreaming
        ) { baseKey in
            // When switching base model, preserve current effort level if possible
            let effort = currentEffortFromModel
            if let resolvedID = resolveModelID(baseKey: baseKey, effort: effort) {
                Task { await viewModel.setModel(resolvedID) }
            }
        }
    }

    // MARK: - Effort Dropdown (derived from model variants + ACP config fallback)

    private static let defaultEffortOptions: [(id: String, name: String)] = [
        ("low", "Low"),
        ("medium", "Medium"),
        ("high", "High"),
    ]

    private var effortDropdown: some View {
        let modelEfforts = effortLevelsForCurrentModel
        let hasModelEfforts = !modelEfforts.isEmpty

        // Prefer effort levels parsed from model variants; fall back to ACP config option; then defaults
        let effortOption = viewModel.configOptions.first { $0.id.value == "effort" || $0.id.value == "reasoning_effort" }

        let options: [(id: String, name: String)] = {
            if hasModelEfforts { return modelEfforts }
            guard let effortOption, case let .select(select) = effortOption.kind else {
                return Self.defaultEffortOptions
            }
            switch select.options {
            case let .ungrouped(opts): return opts.map { ($0.value.value, $0.name) }
            case let .grouped(groups): return groups.flatMap(\.options).map { ($0.value.value, $0.name) }
            }
        }()

        let currentValue: String = {
            if hasModelEfforts, let effort = currentEffortFromModel { return effort }
            if let key = effortOption?.id.value, let stored = viewModel.configOptionValues[key] { return stored }
            if let effortOption, case let .select(select) = effortOption.kind { return select.currentValue.value }
            return "high"
        }()

        return MetaBarDropdown(
            icon: "gauge.with.dots.needle.33percent",
            label: "Effort",
            options: options,
            selection: currentValue,
            disabled: viewModel.isStreaming
        ) { value in
            if hasModelEfforts, let baseKey = currentBaseKey,
               let resolvedID = resolveModelID(baseKey: baseKey, effort: value)
            {
                // Effort is encoded in model ID — switch model variant
                Task { await viewModel.setModel(resolvedID) }
            } else {
                // Effort is a separate ACP config option
                let key = effortOption?.id.value ?? "effort"
                Task { await viewModel.setConfigOption(key: key, value: value) }
            }
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

    @State private var isSendHovering = false

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
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(isSendHovering ? 0.2 : 0.12))
                        Circle()
                            .strokeBorder(Color.red.opacity(isSendHovering ? 0.8 : 0.6), lineWidth: 1.5)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.red.opacity(0.9))
                    }
                } else {
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
            .shadow(
                color: isSendHovering && (canSend || viewModel.isStreaming) ? .black.opacity(0.2) : .clear,
                radius: isSendHovering ? 8 : 0,
                y: isSendHovering ? 2 : 0
            )
            .offset(y: isSendHovering && (canSend || viewModel.isStreaming) ? -1 : 0)
            .scaleEffect(isSendHovering && (canSend || viewModel.isStreaming) ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isStreaming && !canSend)
        .onHover { isSendHovering = $0 }
        .animation(.easeOut(duration: ChatTokens.durFast), value: isSendHovering)
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
