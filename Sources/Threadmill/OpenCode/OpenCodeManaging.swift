import Foundation

protocol OpenCodeManaging: AnyObject {
    func listSessions(directory: String) async throws -> [OCSession]
    func getSession(id: String, directory: String) async throws -> OCSession
    func createSession(directory: String) async throws -> OCSession
    func initSession(id: String, directory: String) async throws -> OCSession
    func getMessages(sessionID: String, directory: String) async throws -> [OCMessage]
    func sendPrompt(sessionID: String, prompt: String, directory: String) async throws
    func abort(sessionID: String, directory: String) async throws
    func getSessionDiff(sessionID: String, directory: String) async throws -> OCDiff
    func healthCheck() async throws -> Bool
    func streamEvents(directory: String) -> AsyncStream<OCEvent>
}
