import ACPModel
import Foundation

struct ChatHistoryResponse: Decodable {
    let updates: [SessionUpdateNotification]
    let nextCursor: UInt64?

    enum CodingKeys: String, CodingKey {
        case updates
        case nextCursor = "next_cursor"
    }
}

struct ChatSessionInfo: Decodable, Equatable {
    var sessionID: String
    var threadID: String
    var agentStatusValue: String?
    var workerCount: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case threadID = "thread_id"
        case agentStatusValue = "agent_status"
        case workerCount = "worker_count"
    }

    init(sessionID: String, threadID: String, agentStatusValue: String?, workerCount: Int) {
        self.sessionID = sessionID
        self.threadID = threadID
        self.agentStatusValue = agentStatusValue
        self.workerCount = workerCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        threadID = try container.decode(String.self, forKey: .threadID)
        agentStatusValue = try container.decodeIfPresent(String.self, forKey: .agentStatusValue)
        workerCount = try container.decodeIfPresent(Int.self, forKey: .workerCount) ?? 0
    }

    var agentStatus: AgentStatus? {
        AgentStatus.fromDaemonStatus(agentStatusValue ?? "", workerCount: workerCount)
    }

    mutating func applyStatusUpdate(status: String, workerCount: Int) {
        agentStatusValue = status
        self.workerCount = workerCount
    }
}

extension ChatSessionInfo {
    init?(payload: [String: Any]) {
        guard
            let sessionID = payload["session_id"] as? String,
            let threadID = payload["thread_id"] as? String
        else {
            return nil
        }

        self.sessionID = sessionID
        self.threadID = threadID
        agentStatusValue = payload["agent_status"] as? String
        workerCount = Self.parseInteger(payload["worker_count"]) ?? 0
    }

    private static func parseInteger(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text)
        }
        return nil
    }
}
