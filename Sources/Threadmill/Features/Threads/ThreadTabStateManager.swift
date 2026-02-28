import Foundation

@MainActor
final class ThreadTabStateManager {
    struct ThreadState: Codable, Equatable {
        var selectedMode: String = TabItem.chat.id
        var selectedSessionIDs: [String: String] = [:]
        var terminalSessionIDs: [String] = []
    }

    private struct PersistedState: Codable {
        var threads: [String: ThreadState] = [:]
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var threadStates: [String: ThreadState]

    init(defaults: UserDefaults = .standard, storageKey: String = "threadmill.thread-tab-state") {
        self.defaults = defaults
        self.storageKey = storageKey

        if
            let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(PersistedState.self, from: data)
        {
            threadStates = decoded.threads
        } else {
            threadStates = [:]
        }
    }

    func selectedMode(threadID: String) -> String {
        threadStates[threadID]?.selectedMode ?? TabItem.chat.id
    }

    func setSelectedMode(_ modeID: String, threadID: String) {
        var state = threadStates[threadID] ?? ThreadState()
        state.selectedMode = modeID
        threadStates[threadID] = state
        persist()
    }

    func selectedSessionID(modeID: String, threadID: String) -> String? {
        threadStates[threadID]?.selectedSessionIDs[modeID]
    }

    func setSelectedSessionID(_ sessionID: String?, modeID: String, threadID: String) {
        var state = threadStates[threadID] ?? ThreadState()
        state.selectedSessionIDs[modeID] = sessionID
        threadStates[threadID] = state
        persist()
    }

    func terminalSessionIDs(threadID: String) -> [String] {
        threadStates[threadID]?.terminalSessionIDs ?? []
    }

    func setTerminalSessionIDs(_ sessionIDs: [String], threadID: String) {
        var state = threadStates[threadID] ?? ThreadState()
        var seen = Set<String>()
        state.terminalSessionIDs = sessionIDs.filter { seen.insert($0).inserted }
        threadStates[threadID] = state
        persist()
    }

    static func modeIDForShortcut(index: Int, visibleModeIDs: [String]) -> String? {
        guard index > 0, index <= visibleModeIDs.count else {
            return nil
        }
        return visibleModeIDs[index - 1]
    }

    static func nextModeID(after currentModeID: String, visibleModeIDs: [String]) -> String? {
        guard !visibleModeIDs.isEmpty else {
            return nil
        }
        guard let index = visibleModeIDs.firstIndex(of: currentModeID) else {
            return visibleModeIDs.first
        }
        return visibleModeIDs[(index + 1) % visibleModeIDs.count]
    }

    static func previousModeID(before currentModeID: String, visibleModeIDs: [String]) -> String? {
        guard !visibleModeIDs.isEmpty else {
            return nil
        }
        guard let index = visibleModeIDs.firstIndex(of: currentModeID) else {
            return visibleModeIDs.first
        }
        return visibleModeIDs[(index - 1 + visibleModeIDs.count) % visibleModeIDs.count]
    }

    private func persist() {
        let state = PersistedState(threads: threadStates)
        guard let encoded = try? JSONEncoder().encode(state) else {
            return
        }
        defaults.set(encoded, forKey: storageKey)
    }
}
