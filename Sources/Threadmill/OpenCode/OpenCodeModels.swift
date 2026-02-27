import Foundation

struct OCSession: Codable, Identifiable, Equatable {
    let id: String
    let slug: String?
    let title: String
    let directory: String
    let projectID: String
    let version: String?
    let parentID: String?
    let time: OCSessionTime?
    let summary: OCSessionSummary?
}

struct OCSessionTime: Codable, Equatable {
    let created: Double
    let updated: Double
    let compacting: Double?
    let archived: Double?
}

struct OCSessionSummary: Codable, Equatable {
    let additions: Int
    let deletions: Int
    let files: Int
}

struct OCMessage: Codable, Identifiable, Equatable {
    let id: String
    let sessionID: String
    let role: String
    let parts: [OCMessagePart]
    let agent: String?
    let time: OCMessageTime?
    let model: OCMessageModel?

    init(
        id: String,
        sessionID: String,
        role: String,
        parts: [OCMessagePart] = [],
        agent: String? = nil,
        time: OCMessageTime? = nil,
        model: OCMessageModel? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.parts = parts
        self.agent = agent
        self.time = time
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case role
        case parts
        case agent
        case time
        case model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        role = try container.decode(String.self, forKey: .role)
        parts = try container.decodeIfPresent([OCMessagePart].self, forKey: .parts) ?? []
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        time = try container.decodeIfPresent(OCMessageTime.self, forKey: .time)
        model = try container.decodeIfPresent(OCMessageModel.self, forKey: .model)
    }
}

struct OCMessageTime: Codable, Equatable {
    let created: Double
    let completed: Double?
}

struct OCMessageModel: Codable, Equatable {
    let providerID: String
    let modelID: String
}

struct OCMessagePart: Codable, Identifiable, Equatable {
    let id: String
    let type: String
    let sessionID: String?
    let messageID: String?
    let text: String?
    let raw: [String: OCJSONValue]

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case sessionID
        case messageID
        case text
    }

    init(
        id: String,
        type: String,
        sessionID: String? = nil,
        messageID: String? = nil,
        text: String? = nil,
        raw: [String: OCJSONValue] = [:]
    ) {
        self.id = id
        self.type = type
        self.sessionID = sessionID
        self.messageID = messageID
        self.text = text
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: CodingKeys.self)
        id = try known.decode(String.self, forKey: .id)
        type = try known.decode(String.self, forKey: .type)

        let dynamic = try decoder.container(keyedBy: OCDynamicCodingKey.self)
        var raw: [String: OCJSONValue] = [:]
        for key in dynamic.allKeys {
            raw[key.stringValue] = try dynamic.decode(OCJSONValue.self, forKey: key)
        }
        self.raw = raw

        sessionID =
            try known.decodeIfPresent(String.self, forKey: .sessionID)
            ?? raw.caseInsensitiveString(for: ["sessionID", "sessionId", "session_id"])
        messageID =
            try known.decodeIfPresent(String.self, forKey: .messageID)
            ?? raw.caseInsensitiveString(for: ["messageID", "messageId", "message_id"])

        let explicitText = try known.decodeIfPresent(String.self, forKey: .text)
        text = explicitText ?? raw.caseInsensitiveString(for: ["text", "reasoning", "thinking", "content"])
    }

    func encode(to encoder: Encoder) throws {
        var dynamic = encoder.container(keyedBy: OCDynamicCodingKey.self)

        var merged = raw
        merged["id"] = .string(id)
        merged["type"] = .string(type)
        if let sessionID {
            merged["sessionID"] = .string(sessionID)
        }
        if let messageID {
            merged["messageID"] = .string(messageID)
        }
        if let text {
            merged["text"] = .string(text)
        }

        for (key, value) in merged {
            guard let codingKey = OCDynamicCodingKey(stringValue: key) else {
                continue
            }
            try dynamic.encode(value, forKey: codingKey)
        }
    }
}

struct OCProvider: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let models: [OCModel]
}

struct OCModel: Codable, Identifiable, Equatable {
    let id: String
    let name: String
}

struct OCAgent: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
    }

    init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let id = try container.decodeIfPresent(String.self, forKey: .id) ?? name

        self.init(
            id: id,
            name: name,
            description: try container.decodeIfPresent(String.self, forKey: .description)
        )
    }
}

struct OCDiff: Codable, Equatable {
    let files: [OCDiffFile]
}

struct OCDiffFile: Codable, Equatable {
    let file: String
    let before: String
    let after: String
    let additions: Int
    let deletions: Int
    let status: String?
}

struct OCMessagePartUpdate: Codable, Equatable {
    let part: OCMessagePart
    let delta: String?
}

struct OCSessionStatusEvent: Codable, Equatable {
    let sessionID: String
    let status: OCSessionStatus
}

struct OCSessionStatus: Codable, Equatable {
    let type: String
    let attempt: Int?
    let message: String?
    let next: Double?
}

enum OCEvent {
    case sessionUpdated(OCSession)
    case messageUpdated(OCMessage)
    case messagePartUpdated(OCMessagePartUpdate)
    case sessionStatus(OCSessionStatusEvent)
    case unknown(String, Data)
}

enum OCJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: OCJSONValue])
    case array([OCJSONValue])
    case null

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: OCJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([OCJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct OCDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension Dictionary where Key == String, Value == OCJSONValue {
    func caseInsensitiveString(for keys: [String]) -> String? {
        for key in keys {
            if let exact = self[key]?.stringValue, !exact.isEmpty {
                return exact
            }
            if let matched = first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value.stringValue,
               !matched.isEmpty
            {
                return matched
            }
        }
        return nil
    }
}
