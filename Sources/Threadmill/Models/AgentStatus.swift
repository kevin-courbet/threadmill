import Foundation

enum AgentStatus: Equatable {
    case idle
    case busy(workerCount: Int)
    case stalled(workerCount: Int)

    static func fromDaemonStatus(_ status: String, workerCount: Int) -> AgentStatus? {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "idle":
            return .idle
        case "busy":
            return .busy(workerCount: workerCount)
        case "stalled":
            return .stalled(workerCount: workerCount)
        default:
            return nil
        }
    }
}

struct AgentActivityInfo: Equatable {
    let status: AgentStatus
    let workerCount: Int
    let lastUpdateTime: Date
}
