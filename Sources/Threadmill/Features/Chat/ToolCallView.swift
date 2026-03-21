import Foundation
import SwiftUI

struct ToolCallView: View {
    let part: OCMessagePart
    var depth: Int = 0

    @State private var isExpanded = false

    private var payload: ToolPayload {
        ToolPayload(part: part)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    statusIndicator

                    VStack(alignment: .leading, spacing: 1) {
                        Text(payload.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)

                        if let title = payload.title, !title.isEmpty {
                            Text(title)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let arguments = payload.arguments {
                        section(title: "Arguments") {
                            contentView(text: arguments, preferredLanguage: nil)
                        }
                    }

                    if let result = payload.result {
                        section(title: "Result") {
                            contentView(text: result, preferredLanguage: payload.preferredLanguage)
                        }
                    }

                    if !payload.children.isEmpty {
                        section(title: "Nested") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(payload.children) { child in
                                    ToolCallView(part: child, depth: depth + 1)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .font(.system(size: 11, weight: .regular))
        .padding(6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .padding(.leading, CGFloat(depth) * 12)
    }

    private var statusIndicator: some View {
        Group {
            switch payload.status {
            case .running:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
            case .failure:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.red)
            case .idle:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .frame(width: 12, height: 12)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func contentView(text: String, preferredLanguage: String?) -> some View {
        if ToolPayload.looksLikeDiff(text) {
            InlineDiffView(text: text)
        } else if let fenced = ToolPayload.fencedCode(in: text) {
            CodeBlockView(code: fenced.code, language: fenced.language ?? preferredLanguage)
        } else if ToolPayload.looksLikeCode(text) {
            CodeBlockView(code: text, language: preferredLanguage)
        } else {
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 170)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }
}

private func chatFormattedJSON(_ value: OCJSONValue) -> String? {
    chatFormattedJSON(value.foundationValue)
}

private func chatFormattedJSON(_ object: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(object) else {
        return nil
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

private extension OCJSONValue {
    var foundationValue: Any {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .bool(value):
            return value
        case let .object(value):
            return value.mapValues(\.foundationValue)
        case let .array(value):
            return value.map(\.foundationValue)
        case .null:
            return NSNull()
        }
    }
}

private enum ToolExecutionStatus {
    case running
    case success
    case failure
    case idle
}

private struct ToolPayload {
    let name: String
    let title: String?
    let status: ToolExecutionStatus
    let arguments: String?
    let result: String?
    let preferredLanguage: String?
    let children: [OCMessagePart]

    init(part: OCMessagePart) {
        let raw = part.raw

        name = ToolPayload.string(in: raw, keys: ["tool", "toolName", "name", "command"]) ?? part.type
        title = ToolPayload.string(in: raw, keys: ["title", "summary", "description"])

        let statusText = ToolPayload.string(in: raw, keys: ["status", "state", "phase"])
        let successFlag = ToolPayload.bool(in: raw, key: "success")
        status = ToolPayload.resolveStatus(text: statusText, success: successFlag)

        arguments = ToolPayload.section(in: raw, keys: ["input", "args", "arguments", "params", "command", "request"])
        result = ToolPayload.section(in: raw, keys: ["output", "result", "response", "diff", "patch", "stdout", "stderr"]) ?? part.text

        preferredLanguage = ToolPayload.string(in: raw, keys: ["language", "lang", "shell"])
        children = ToolPayload.childParts(in: raw, fallbackPart: part)
    }

    private static func resolveStatus(text: String?, success: Bool?) -> ToolExecutionStatus {
        if let success {
            return success ? .success : .failure
        }

        guard let text else {
            return .idle
        }

        let value = text.lowercased()
        if value.contains("running") || value.contains("busy") || value.contains("execut") || value.contains("progress") {
            return .running
        }
        if value.contains("success") || value.contains("ok") || value.contains("done") || value.contains("complete") {
            return .success
        }
        if value.contains("error") || value.contains("fail") || value.contains("cancel") {
            return .failure
        }
        return .idle
    }

    static func string(in raw: [String: OCJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = raw[key]?.stringValue, !value.isEmpty {
                return value
            }
            if let value = raw.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value.stringValue,
               !value.isEmpty
            {
                return value
            }
        }
        return nil
    }

    static func bool(in raw: [String: OCJSONValue], key: String) -> Bool? {
        if let exact = raw[key], case let .bool(value) = exact {
            return value
        }
        if let match = raw.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value,
           case let .bool(value) = match
        {
            return value
        }
        return nil
    }

    static func section(in raw: [String: OCJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let exact = raw[key] {
                return exact.stringValue ?? chatFormattedJSON(exact)
            }
            if let match = raw.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
                return match.stringValue ?? chatFormattedJSON(match)
            }
        }
        return nil
    }

    static func childParts(in raw: [String: OCJSONValue], fallbackPart: OCMessagePart) -> [OCMessagePart] {
        let keys = ["children", "calls", "toolCalls", "tool_calls", "subagent", "subcalls"]

        for key in keys {
            guard let value = raw[key] ?? raw.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value else {
                continue
            }

            guard case let .array(items) = value else {
                continue
            }

            let parts = items.compactMap { item -> OCMessagePart? in
                guard case let .object(object) = item else {
                    return nil
                }

                let id = string(in: object, keys: ["id", "callID", "call_id"]) ?? UUID().uuidString
                let type = string(in: object, keys: ["type", "kind"]) ?? "tool"
                let text = section(in: object, keys: ["output", "result", "response", "text"]) ?? string(in: object, keys: ["text"])

                return OCMessagePart(
                    id: id,
                    type: type,
                    sessionID: fallbackPart.sessionID,
                    messageID: fallbackPart.messageID,
                    text: text,
                    raw: object
                )
            }

            if !parts.isEmpty {
                return parts
            }
        }

        return []
    }

    static func looksLikeDiff(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let hasAdd = lines.contains { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
        let hasRemove = lines.contains { $0.hasPrefix("-") && !$0.hasPrefix("---") }
        return hasAdd && hasRemove
    }

    static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 2 else {
            return false
        }
        let codeSignals = ["{", "}", "=>", "func ", "let ", "var ", "class ", "import ", "$ ", "#!/", "def ", "SELECT ", "FROM ", "WHERE "]
        return lines.contains { line in
            codeSignals.contains { line.localizedCaseInsensitiveContains($0) }
        }
    }

    static func fencedCode(in text: String) -> (language: String?, code: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else {
            return nil
        }

        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else {
            return nil
        }

        let languageChunk = String(first.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let language = languageChunk.isEmpty ? nil : languageChunk
        let code = lines.dropFirst().dropLast().joined(separator: "\n")
        return (language, code)
    }
}
