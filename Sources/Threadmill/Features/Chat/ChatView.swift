import SwiftUI

struct ChatView: View {
    let directory: String

    @State private var viewModel: ChatViewModel
    @State private var draftText = ""
    @State private var expandedToolPartIDs: Set<String> = []

    init(
        directory: String,
        openCodeClient: any OpenCodeManaging,
        ensureOpenCodeRunning: (() async throws -> Void)? = nil
    ) {
        self.directory = directory
        _viewModel = State(initialValue: ChatViewModel(openCodeClient: openCodeClient, ensureOpenCodeRunning: ensureOpenCodeRunning))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList

            if let lastError = viewModel.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            ChatInputView(
                text: $draftText,
                sessions: viewModel.sessions,
                currentSessionID: viewModel.currentSession?.id,
                isGenerating: viewModel.isGenerating,
                onSelectSession: { sessionID in
                    Task {
                        await viewModel.selectSession(id: sessionID)
                    }
                },
                onCreateSession: {
                    Task {
                        await viewModel.createSession(directory: directory)
                    }
                },
                onSend: sendPrompt,
                onAbort: {
                    Task {
                        await viewModel.abort()
                    }
                }
            )
        }
        .background(Color.black.opacity(0.92))
        .task(id: directory) {
            await viewModel.loadSessions(directory: directory)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }

                    if viewModel.isGenerating {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Generating response...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("chat-bottom")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .onChange(of: viewModel.messages) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.streamingParts) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.isGenerating) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: OCMessage) -> some View {
        let isUser = message.role.lowercased() == "user"

        HStack {
            if isUser {
                Spacer(minLength: 24)
            }

            VStack(alignment: .leading, spacing: 8) {
                if message.parts.isEmpty {
                    Text(isUser ? "(empty prompt)" : "...")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(message.parts) { part in
                        partView(part, role: message.role)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isUser
                    ? Color.accentColor.opacity(0.18)
                    : Color.white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .frame(maxWidth: 820, alignment: .leading)

            if !isUser {
                Spacer(minLength: 24)
            }
        }
    }

    @ViewBuilder
    private func partView(_ part: OCMessagePart, role: String) -> some View {
        if isToolPart(part) {
            toolPartView(part)
        } else if let text = part.text, !text.isEmpty {
            if role.lowercased() == "assistant" {
                assistantText(text)
            } else {
                Text(text)
                    .textSelection(.enabled)
            }
        } else if !part.raw.isEmpty, let rawDump = formattedJSON(part.raw.foundationValue) {
            Text(rawDump)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func assistantText(_ text: String) -> some View {
        if text.contains("```") {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        } else if let attributed = try? AttributedString(markdown: text) {
            Text(attributed)
                .textSelection(.enabled)
        } else {
            Text(text)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func toolPartView(_ part: OCMessagePart) -> some View {
        DisclosureGroup(isExpanded: disclosureBinding(for: part.id)) {
            VStack(alignment: .leading, spacing: 8) {
                if let args = toolSectionText(part: part, keys: ["input", "args", "arguments"]) {
                    Text("Arguments")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(args)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                if let result = toolSectionText(part: part, keys: ["output", "result", "response"]) ?? part.text {
                    Text("Result")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(result)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(toolTitle(for: part))
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("chat-bottom", anchor: .bottom)
        }
    }

    private func sendPrompt() {
        let outgoingText = draftText
        draftText = ""
        Task {
            await viewModel.sendPrompt(text: outgoingText)
        }
    }

    private func disclosureBinding(for partID: String) -> Binding<Bool> {
        Binding(
            get: { expandedToolPartIDs.contains(partID) },
            set: { isExpanded in
                if isExpanded {
                    expandedToolPartIDs.insert(partID)
                } else {
                    expandedToolPartIDs.remove(partID)
                }
            }
        )
    }

    private func isToolPart(_ part: OCMessagePart) -> Bool {
        if part.type.localizedCaseInsensitiveContains("tool") {
            return true
        }
        return part.raw.keys.contains { key in
            key.localizedCaseInsensitiveContains("tool")
        }
    }

    private func toolTitle(for part: OCMessagePart) -> String {
        for key in ["tool", "toolName", "name"] {
            if let value = part.raw[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        return part.type
    }

    private func toolSectionText(part: OCMessagePart, keys: [String]) -> String? {
        for key in keys {
            guard let value = part.raw[key] else {
                continue
            }

            if case let .string(text) = value {
                return text
            }

            if let json = formattedJSON(value) {
                return json
            }
        }

        return nil
    }

    private func formattedJSON(_ value: OCJSONValue) -> String? {
        formattedJSON(value.foundationValue)
    }

    private func formattedJSON(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private extension OCJSONValue {
    var foundationValue: Any {
        switch self {
        case let .string(value):
            value
        case let .number(value):
            value
        case let .bool(value):
            value
        case let .object(value):
            value.mapValues(\.foundationValue)
        case let .array(value):
            value.map(\.foundationValue)
        case .null:
            NSNull()
        }
    }
}

private extension Dictionary where Key == String, Value == OCJSONValue {
    var foundationValue: [String: Any] {
        mapValues(\.foundationValue)
    }
}
