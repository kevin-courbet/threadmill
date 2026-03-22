import Foundation

struct OCSession: Codable, Identifiable, Equatable {
    let id: String
    let slug: String?
    let title: String?
    let directory: String?
    let projectID: String?
    let version: String?
    let parentID: String?
    let time: OCSessionTime?
    let summary: String?

    init(
        id: String,
        slug: String? = nil,
        title: String? = nil,
        directory: String? = nil,
        projectID: String? = nil,
        version: String? = nil,
        parentID: String? = nil,
        time: OCSessionTime? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.directory = directory
        self.projectID = projectID
        self.version = version
        self.parentID = parentID
        self.time = time
        self.summary = summary
    }
}

struct OCSessionTime: Codable, Equatable {
    let created: TimeInterval?
    let updated: TimeInterval?
}

struct OCMessage: Codable, Identifiable, Equatable {
    let id: String
    let sessionID: String
    let role: String
    let parts: [OCMessagePart]
    let time: OCMessageTime?

    init(
        id: String,
        sessionID: String,
        role: String,
        parts: [OCMessagePart] = [],
        time: OCMessageTime? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.parts = parts
        self.time = time
    }
}

struct OCMessageTime: Codable, Equatable {
    let created: TimeInterval?
    let completed: TimeInterval?
}

struct OCMessagePart: Codable, Identifiable, Equatable {
    let id: String
    let type: String
    let sessionID: String
    let messageID: String
    let text: String?
    let raw: [String: OCJSONValue]

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case sessionID
        case messageID
        case text
        case raw
    }

    init(
        id: String,
        type: String,
        sessionID: String,
        messageID: String,
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
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        messageID = try container.decode(String.self, forKey: .messageID)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        raw = try container.decodeIfPresent([String: OCJSONValue].self, forKey: .raw) ?? [:]
    }
}

struct OCDiff: Codable, Equatable {
    let files: [String]
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
    let next: String?
}

enum OCEvent {
    case sessionUpdated(OCSession)
    case messageUpdated(OCMessage)
    case messagePartUpdated(OCMessagePartUpdate)
    case sessionStatus(OCSessionStatusEvent)
}

enum OCJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: OCJSONValue])
    case array([OCJSONValue])
    case null

    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
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
