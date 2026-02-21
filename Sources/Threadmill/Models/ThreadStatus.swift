import Foundation

enum ThreadStatus: String, Codable, CaseIterable {
    case creating
    case active
    case closing
    case closed
    case hidden
    case failed
}
