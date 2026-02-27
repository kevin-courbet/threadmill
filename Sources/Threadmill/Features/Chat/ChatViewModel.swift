import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    var sessions: [OCSession] = []
    var currentSession: OCSession?
    var messages: [OCMessage] = []
    var isGenerating = false
    var streamingParts: [String: OCMessagePart] = [:]

    var lastError: String?

    private let openCodeClient: any OpenCodeManaging
    private let ensureOpenCodeRunning: (() async throws -> Void)?
    private var activeDirectory: String?
    private var hasEnsuredOpenCodeRunning = false
    private var eventStreamDirectory: String?
    private var eventStreamTask: Task<Void, Never>?
    private var eventStreamToken = UUID()
    private var messageLoadTask: Task<Void, Never>?
    private var messageLoadToken = UUID()

    init(
        openCodeClient: any OpenCodeManaging,
        ensureOpenCodeRunning: (() async throws -> Void)? = nil
    ) {
        self.openCodeClient = openCodeClient
        self.ensureOpenCodeRunning = ensureOpenCodeRunning
    }

    @MainActor deinit {
        eventStreamTask?.cancel()
        messageLoadTask?.cancel()
    }

    func loadSessions(directory: String) async {
        if activeDirectory != directory {
            sessions = []
            currentSession = nil
            messages = []
            streamingParts = [:]
            lastError = nil
            messageLoadTask?.cancel()
            messageLoadTask = nil
            messageLoadToken = UUID()
        }

        activeDirectory = directory

        do {
            try await ensureOpenCodeRunningIfNeeded()
            startEventStreamIfNeeded(directory: directory)
            let loadedSessions = try await openCodeClient.listSessions(directory: directory)
            sessions = loadedSessions.sorted { lhs, rhs in
                (lhs.time?.updated ?? 0) > (rhs.time?.updated ?? 0)
            }

            if let currentSession, let refreshed = sessions.first(where: { $0.id == currentSession.id }) {
                self.currentSession = refreshed
            } else {
                currentSession = sessions.first
            }

            if let currentSession {
                await loadMessages(sessionID: currentSession.id, directory: directory)
            } else {
                messages = []
                streamingParts = [:]
            }
        } catch {
            sessions = []
            currentSession = nil
            messages = []
            streamingParts = [:]
            lastError = error.localizedDescription
        }
    }

    func sendPrompt(text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return
        }
        guard let directory = activeDirectory else {
            return
        }

        do {
            try await ensureOpenCodeRunningIfNeeded()
        } catch {
            lastError = error.localizedDescription
            return
        }

        if currentSession == nil {
            await createSession(directory: directory)
        }

        guard let sessionID = currentSession?.id else {
            return
        }

        isGenerating = true
        lastError = nil
        startEventStreamIfNeeded(directory: directory)

        do {
            try await openCodeClient.sendPrompt(sessionID: sessionID, prompt: prompt, directory: directory)
        } catch {
            isGenerating = false
            lastError = error.localizedDescription
        }
    }

    func abort() async {
        guard
            let sessionID = currentSession?.id,
            let directory = activeDirectory
        else {
            return
        }

        do {
            try await ensureOpenCodeRunningIfNeeded()
            try await openCodeClient.abort(sessionID: sessionID, directory: directory)
        } catch {
            lastError = error.localizedDescription
        }

        isGenerating = false
    }

    func selectSession(id: String) async {
        guard let directory = activeDirectory else {
            return
        }
        guard let session = sessions.first(where: { $0.id == id }) else {
            return
        }

        currentSession = session
        streamingParts = [:]
        await loadMessages(sessionID: id, directory: directory)
    }

    func createSession(directory: String) async {
        activeDirectory = directory

        do {
            try await ensureOpenCodeRunningIfNeeded()
            startEventStreamIfNeeded(directory: directory)
            let newSession = try await openCodeClient.createSession(directory: directory)
            upsertSession(newSession)
            currentSession = newSession
            messages = []
            streamingParts = [:]
            await loadMessages(sessionID: newSession.id, directory: directory)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadMessages(sessionID: String, directory: String) async {
        messageLoadTask?.cancel()
        let token = UUID()
        messageLoadToken = token

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.ensureOpenCodeRunningIfNeeded()
                let loadedMessages = try await self.openCodeClient.getMessages(sessionID: sessionID, directory: directory)
                guard !Task.isCancelled else {
                    return
                }
                guard self.messageLoadToken == token, self.currentSession?.id == sessionID, self.activeDirectory == directory else {
                    return
                }
                self.messages = loadedMessages
                self.streamingParts = [:]
            } catch is CancellationError {
                return
            } catch {
                guard self.messageLoadToken == token, self.currentSession?.id == sessionID, self.activeDirectory == directory else {
                    return
                }
                self.messages = []
                self.streamingParts = [:]
                self.lastError = error.localizedDescription
            }
        }

        messageLoadTask = task
        await task.value

        if messageLoadToken == token {
            messageLoadTask = nil
        }
    }

    private func startEventStreamIfNeeded(directory: String) {
        if eventStreamDirectory == directory, eventStreamTask != nil {
            return
        }

        eventStreamTask?.cancel()
        eventStreamDirectory = directory
        let token = UUID()
        eventStreamToken = token

        let eventStream = openCodeClient.streamEvents(directory: directory)
        eventStreamTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.eventStreamToken == token {
                    self.eventStreamTask = nil
                }
            }

            for await event in eventStream {
                if Task.isCancelled {
                    return
                }
                guard let self else {
                    return
                }
                self.handleEvent(event, directory: directory)
            }
        }
    }

    private func ensureOpenCodeRunningIfNeeded() async throws {
        guard !hasEnsuredOpenCodeRunning else {
            return
        }

        try await ensureOpenCodeRunning?()
        hasEnsuredOpenCodeRunning = true
    }

    private func handleEvent(_ event: OCEvent, directory: String) {
        guard activeDirectory == directory else {
            return
        }

        switch event {
        case let .sessionUpdated(session):
            upsertSession(session)
            if currentSession?.id == session.id {
                currentSession = session
            }

        case let .messageUpdated(message):
            guard message.sessionID == currentSession?.id else {
                return
            }
            upsertMessage(message, preserveExistingParts: true)

        case let .messagePartUpdated(update):
            applyPartUpdate(update)

        case let .sessionStatus(statusEvent):
            guard statusEvent.sessionID == currentSession?.id else {
                return
            }

            let normalized = statusEvent.status.type.lowercased()
            let stillRunning = normalized == "busy" || normalized == "running"
            isGenerating = stillRunning
            if !stillRunning {
                streamingParts = [:]
            }

        case let .unknown(type, payload):
            if type == "stream.error" {
                lastError = String(data: payload, encoding: .utf8) ?? "Unknown stream error"
                isGenerating = false
            }
        }
    }

    private func applyPartUpdate(_ update: OCMessagePartUpdate) {
        guard let sessionID = currentSession?.id else {
            return
        }

        let partSessionID = update.part.sessionID ?? update.part.raw["sessionID"]?.stringValue
        if let partSessionID, partSessionID != sessionID {
            return
        }

        guard let messageID = update.part.messageID ?? update.part.raw["messageID"]?.stringValue else {
            return
        }

        if let messageIndex = messages.firstIndex(where: { $0.id == messageID }) {
            var parts = messages[messageIndex].parts
            let existingPart = parts.first(where: { $0.id == update.part.id })
            let mergedPart = mergedPart(from: update, existingPart: existingPart)
            streamingParts[mergedPart.id] = mergedPart

            if let partIndex = parts.firstIndex(where: { $0.id == mergedPart.id }) {
                parts[partIndex] = mergedPart
            } else {
                parts.append(mergedPart)
            }

            messages[messageIndex] = messages[messageIndex].with(parts: parts)
            return
        }

        let mergedPart = mergedPart(from: update, existingPart: nil)
        streamingParts[mergedPart.id] = mergedPart
        let placeholderMessage = OCMessage(
            id: messageID,
            sessionID: sessionID,
            role: "assistant",
            parts: [mergedPart]
        )
        messages.append(placeholderMessage)
    }

    private func mergedPart(from update: OCMessagePartUpdate, existingPart: OCMessagePart?) -> OCMessagePart {
        let mergedRaw = (existingPart?.raw ?? [:]).merging(update.part.raw) { _, new in new }
        let mergedText: String?

        if let delta = update.delta {
            if let current = existingPart?.text {
                if let explicitText = update.part.text, !explicitText.isEmpty, explicitText != current {
                    mergedText = explicitText
                } else {
                    mergedText = current + delta
                }
            } else if let explicitText = update.part.text, !explicitText.isEmpty {
                mergedText = explicitText
            } else {
                mergedText = delta
            }
        } else {
            mergedText = update.part.text ?? existingPart?.text
        }

        return OCMessagePart(
            id: update.part.id,
            type: update.part.type,
            sessionID: update.part.sessionID ?? existingPart?.sessionID,
            messageID: update.part.messageID ?? existingPart?.messageID,
            text: mergedText,
            raw: mergedRaw
        )
    }

    private func upsertSession(_ session: OCSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }

    private func upsertMessage(_ message: OCMessage, preserveExistingParts: Bool) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            let parts = preserveExistingParts && message.parts.isEmpty ? messages[index].parts : message.parts
            messages[index] = message.with(parts: parts)
        } else {
            messages.append(message)
        }
    }

}

private extension OCMessage {
    func with(parts: [OCMessagePart]) -> OCMessage {
        OCMessage(
            id: id,
            sessionID: sessionID,
            role: role,
            parts: parts,
            agent: agent,
            time: time,
            model: model
        )
    }
}
