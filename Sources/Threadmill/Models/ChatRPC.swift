import ACPModel
import Foundation

enum AgentStatus: Equatable {
    case idle
    case busy(workerCount: Int)
    case stalled(workerCount: Int)

    static func from(rawStatus: String, workerCount: Int) -> AgentStatus {
        switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "busy":
            return .busy(workerCount: workerCount)
        case "stalled":
            return .stalled(workerCount: workerCount)
        default:
            return .idle
        }
    }
}

struct AgentActivityInfo: Equatable {
    let status: AgentStatus
    let workerCount: Int
    let lastUpdateTime: Date

    static func from(rawStatus: String, workerCount: Int, lastUpdateTime: Date = Date()) -> AgentActivityInfo {
        AgentActivityInfo(
            status: .from(rawStatus: rawStatus, workerCount: workerCount),
            workerCount: workerCount,
            lastUpdateTime: lastUpdateTime
        )
    }
}

struct ChatStartParams: Codable, Equatable {
    let threadID: String
    let agentName: String

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case agentName = "agent_name"
    }
}

struct ChatLoadParams: Codable, Equatable {
    let threadID: String
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case sessionID = "session_id"
    }
}

struct ChatStopParams: Codable, Equatable {
    let threadID: String
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case sessionID = "session_id"
    }
}

struct ChatListParams: Codable, Equatable {
    let threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
    }
}

struct ChatAttachParams: Codable, Equatable {
    let threadID: String
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case sessionID = "session_id"
    }
}

struct ChatDetachParams: Codable, Equatable {
    let channelID: UInt16

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
    }
}

struct ChatHistoryParams: Codable, Equatable {
    let threadID: String
    let sessionID: String
    let cursor: UInt64?

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case sessionID = "session_id"
        case cursor
    }
}

struct ChatModeCapability: Codable, Equatable, Identifiable {
    let id: String
    let title: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
    }

    init(id: String, title: String? = nil) {
        self.id = id
        self.title = title
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let value = try? singleValue.decode(String.self)
        {
            self.id = value
            self.title = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .name)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
    }
}

struct ChatModelCapability: Codable, Equatable, Identifiable {
    let id: String
    let title: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
    }

    init(id: String, title: String? = nil) {
        self.id = id
        self.title = title
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let value = try? singleValue.decode(String.self)
        {
            self.id = value
            self.title = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .name)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
    }
}

struct ChatSessionCapabilities: Codable, Equatable {
    let modes: [ChatModeCapability]
    let models: [ChatModelCapability]
    let currentModeID: String?
    let currentModelID: String?

    init(
        modes: [ChatModeCapability] = [],
        models: [ChatModelCapability] = [],
        currentModeID: String? = nil,
        currentModelID: String? = nil
    ) {
        self.modes = modes
        self.models = models
        self.currentModeID = currentModeID
        self.currentModelID = currentModelID
    }

    private enum CodingKeys: String, CodingKey {
        case modes
        case models
    }

    private enum ModesPayloadKeys: String, CodingKey {
        case availableModes
        case available_modes
        case currentModeId
        case current_mode_id
    }

    private enum ModelsPayloadKeys: String, CodingKey {
        case availableModels
        case available_models
        case currentModelId
        case current_model_id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let rawModes = try? container.decode([ChatModeCapability].self, forKey: .modes) {
            modes = rawModes
            currentModeID = nil
        } else if container.contains(.modes) {
            let nested = try container.nestedContainer(keyedBy: ModesPayloadKeys.self, forKey: .modes)
            modes = (try? nested.decode([ChatModeCapability].self, forKey: .availableModes))
                ?? (try? nested.decode([ChatModeCapability].self, forKey: .available_modes))
                ?? []
            currentModeID = (try? nested.decodeIfPresent(String.self, forKey: .currentModeId))
                ?? (try? nested.decodeIfPresent(String.self, forKey: .current_mode_id))
        } else {
            modes = []
            currentModeID = nil
        }

        if let rawModels = try? container.decode([ChatModelCapability].self, forKey: .models) {
            models = rawModels
            currentModelID = nil
        } else if container.contains(.models) {
            let nested = try container.nestedContainer(keyedBy: ModelsPayloadKeys.self, forKey: .models)
            models = (try? nested.decode([ChatModelCapability].self, forKey: .availableModels))
                ?? (try? nested.decode([ChatModelCapability].self, forKey: .available_models))
                ?? []
            currentModelID = (try? nested.decodeIfPresent(String.self, forKey: .currentModelId))
                ?? (try? nested.decodeIfPresent(String.self, forKey: .current_model_id))
        } else {
            models = []
            currentModelID = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        struct EncodedModes: Encodable {
            let availableModes: [ChatModeCapability]
            let currentModeId: String?
        }

        struct EncodedModels: Encodable {
            let availableModels: [ChatModelCapability]
            let currentModelId: String?
        }

        try container.encode(EncodedModes(availableModes: modes, currentModeId: currentModeID), forKey: .modes)
        try container.encode(EncodedModels(availableModels: models, currentModelId: currentModelID), forKey: .models)
    }
}

struct ChatAgentStatusPayload: Codable, Equatable {
    let status: String
    let workerCount: Int
    let lastUpdateTime: Date?

    enum CodingKeys: String, CodingKey {
        case status
        case workerCount = "worker_count"
        case lastUpdateTime = "last_update_time"
    }

    func asActivityInfo(defaultDate: Date = Date()) -> AgentActivityInfo {
        AgentActivityInfo.from(
            rawStatus: status,
            workerCount: workerCount,
            lastUpdateTime: lastUpdateTime ?? defaultDate
        )
    }
}

struct ChatSessionInfo: Codable, Equatable, Identifiable {
    let sessionID: String
    let threadID: String
    let agentName: String?
    let capabilities: ChatSessionCapabilities?
    let agentStatus: ChatAgentStatusPayload?

    var id: String {
        sessionID
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case threadID = "thread_id"
        case agentName = "agent_name"
        case capabilities
        case agentStatus = "agent_status"
    }
}

struct ChatStartResponse: Codable, Equatable {
    let sessionID: String
    let capabilities: ChatSessionCapabilities?
    let agentStatus: ChatAgentStatusPayload?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case capabilities
        case agentStatus = "agent_status"
    }
}

struct ChatLoadResponse: Codable, Equatable {
    let session: ChatSessionInfo
}

struct ChatAttachResponse: Codable, Equatable {
    let channelID: UInt16

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
    }

    init(channelID: UInt16) {
        self.channelID = channelID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(Int.self, forKey: .channelID)
        guard rawID > 0, rawID <= Int(UInt16.max) else {
            throw DecodingError.dataCorruptedError(forKey: .channelID, in: container, debugDescription: "channel_id out of range")
        }
        channelID = UInt16(rawID)
    }
}

struct ChatHistoryResponse: Codable {
    let updates: [SessionUpdateNotification]
    let nextCursor: UInt64?

    enum CodingKeys: String, CodingKey {
        case updates
        case nextCursor = "next_cursor"
    }
}

struct ChatStatusChangedEvent: Codable, Equatable {
    let threadID: String
    let sessionID: String?
    let agentStatus: ChatAgentStatusPayload

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case sessionID = "session_id"
        case agentStatus = "agent_status"
    }
}

struct ChatSessionCreatedEvent: Codable, Equatable {
    let threadID: String
    let session: ChatSessionInfo

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case session
    }
}

struct ChatSessionReadyEvent: Codable, Equatable {
    let threadID: String
    let sessionID: String
    let capabilities: ChatSessionCapabilities

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case sessionID = "session_id"
        case capabilities
    }
}

struct ChatSessionFailedEvent: Codable, Equatable {
    let threadID: String
    let sessionID: String?
    let error: String

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case sessionID = "session_id"
        case error
    }
}

struct ChatSessionEndedEvent: Codable, Equatable {
    let threadID: String
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case sessionID = "session_id"
    }
}
