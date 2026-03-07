import Foundation

enum ChatHarness: String, CaseIterable, Identifiable {
    case openCodeServe = "opencode-serve"

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .openCodeServe:
            return "OpenCode Serve"
        }
    }
}
