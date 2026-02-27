import Foundation

extension OCMessagePart {
    var isToolPart: Bool {
        if type.localizedCaseInsensitiveContains("tool") {
            return true
        }
        return raw.keys.contains { $0.localizedCaseInsensitiveContains("tool") }
    }

    var isReasoningPart: Bool {
        let normalizedType = type.lowercased()
        if normalizedType.contains("reason") || normalizedType.contains("think") || normalizedType == "analysis" {
            return true
        }

        return raw.keys.contains { key in
            let normalizedKey = key.lowercased()
            return normalizedKey.contains("reason") || normalizedKey.contains("think")
        }
    }

    var renderText: String? {
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }

        if let fallback = raw.caseInsensitiveString(for: ["text", "reasoning", "thinking", "content"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !fallback.isEmpty
        {
            return fallback
        }

        return nil
    }

    var isStepBoundaryPart: Bool {
        type.lowercased().hasPrefix("step-")
    }
}

func chatFormattedJSON(_ value: OCJSONValue) -> String? {
    chatFormattedJSON(value.foundationValue)
}

func chatFormattedJSON(_ object: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(object) else {
        return nil
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

extension OCJSONValue {
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

extension Dictionary where Key == String, Value == OCJSONValue {
    var foundationValue: [String: Any] {
        mapValues(\.foundationValue)
    }
}
