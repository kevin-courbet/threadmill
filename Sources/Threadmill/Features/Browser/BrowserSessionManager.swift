import Combine
import Foundation
import WebKit

@MainActor
final class BrowserSessionManager: ObservableObject {
    struct DebugSnapshot: Codable, Equatable {
        let sessionCount: Int
        let activeSessionID: String?
        let currentURL: String
        let pageTitle: String
        let isLoading: Bool
        let loadingProgress: Double
        let canGoBack: Bool
        let canGoForward: Bool
        let loadError: String?

        var summary: String {
            [
                "sessionCount=\(sessionCount)",
                "activeSessionID=\(activeSessionID ?? "nil")",
                "currentURL=\(currentURL)",
                "pageTitle=\(pageTitle)",
                "isLoading=\(isLoading)",
                "loadingProgress=\(loadingProgress)",
                "canGoBack=\(canGoBack)",
                "canGoForward=\(canGoForward)",
                "loadError=\(loadError ?? "nil")",
            ].joined(separator: "\n")
        }
    }

    @Published var sessions: [BrowserSession] = []
    @Published var activeSessionId: String?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL = ""
    @Published var pageTitle = ""
    @Published var isLoading = false
    @Published var loadingProgress = 0.0
    @Published var loadError: String?

    private let databaseManager: any DatabaseManaging
    private let threadID: String
    private let defaultURL: String
    // Retains WKWebViews so they survive tab switches (ZStack opacity pattern)
    private var webViews: [String: WKWebView] = [:]

    init(databaseManager: any DatabaseManaging, thread: ThreadModel) {
        self.databaseManager = databaseManager
        threadID = thread.id
        defaultURL = BrowserSessionManager.defaultURL(portOffset: thread.portOffset)
        reloadSessions()
    }

    var activeSession: BrowserSession? {
        guard let activeSessionId else {
            return nil
        }
        return sessions.first(where: { $0.id == activeSessionId })
    }

    func createSession() {
        createSession(url: defaultURL)
    }

    func createSession(url: String) {
        let session = BrowserSession(threadID: threadID, url: url, order: sessions.count)

        do {
            try databaseManager.saveBrowserSession(session)
            sessions.append(session)
            selectSession(session.id)
        } catch {
            NSLog("threadmill-browser: failed to create browser session: %@", "\(error)")
        }
    }

    func closeSession(_ sessionID: String) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }

        let wasActive = activeSessionId == sessionID
        webViews.removeValue(forKey: sessionID)
        sessions.remove(at: sessionIndex)

        do {
            try databaseManager.deleteBrowserSession(id: sessionID)
            persistSessionOrder()
        } catch {
            NSLog("threadmill-browser: failed to close browser session %@: %@", sessionID, "\(error)")
        }

        if sessions.isEmpty {
            resetNavigationState()
            createSession()
            return
        }

        guard wasActive else {
            if activeSessionId == nil {
                selectSession(sessions[0].id)
            }
            return
        }

        let nextIndex = min(sessionIndex, sessions.count - 1)
        selectSession(sessions[nextIndex].id)
    }

    func selectSession(_ sessionID: String) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return
        }

        activeSessionId = sessionID
        currentURL = session.url
        pageTitle = session.title
        loadError = nil

        if let webView = webViews[sessionID] {
            updateNavigationState(
                canGoBack: webView.canGoBack,
                canGoForward: webView.canGoForward,
                isLoading: webView.isLoading,
                loadingProgress: webView.estimatedProgress
            )
        } else {
            resetNavigationState()
        }
    }

    func handleURLChange(sessionID: String, url: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        guard sessions[index].url != url else {
            return
        }

        sessions[index].url = url
        if activeSessionId == sessionID {
            currentURL = url
        }
        persistSession(sessions[index])
    }

    func handleTitleChange(sessionID: String, title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        guard sessions[index].title != title else {
            return
        }

        sessions[index].title = title
        if activeSessionId == sessionID {
            pageTitle = title
        }
        persistSession(sessions[index])
    }

    func navigateToURL(_ url: String) {
        guard let activeSessionId,
              let index = sessions.firstIndex(where: { $0.id == activeSessionId })
        else {
            return
        }

        currentURL = url
        sessions[index].url = url
        loadError = nil
        persistSession(sessions[index])
    }

    func goBack() {
        guard let id = activeSessionId else { return }
        webViews[id]?.goBack()
    }

    func goForward() {
        guard let id = activeSessionId else { return }
        webViews[id]?.goForward()
    }

    func reload() {
        guard let id = activeSessionId else { return }
        webViews[id]?.reload()
    }

    func registerWebView(_ webView: WKWebView, for sessionID: String) {
        webViews[sessionID] = webView
        if activeSessionId == sessionID {
            updateNavigationState(
                canGoBack: webView.canGoBack,
                canGoForward: webView.canGoForward,
                isLoading: webView.isLoading,
                loadingProgress: webView.estimatedProgress
            )
        }
    }

    func unregisterWebView(for sessionID: String) {
        webViews.removeValue(forKey: sessionID)
    }

    func updateNavigationState(canGoBack: Bool, canGoForward: Bool, isLoading: Bool, loadingProgress: Double) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.loadingProgress = loadingProgress
    }

    func handleLoadError(_ error: String?) {
        loadError = error
        if error != nil {
            isLoading = false
        }
    }

    private func reloadSessions() {
        do {
            sessions = try databaseManager.listBrowserSessions(threadID: threadID)
        } catch {
            NSLog("threadmill-browser: failed to list browser sessions: %@", "\(error)")
            sessions = []
        }

        if let activeSessionId,
           let session = sessions.first(where: { $0.id == activeSessionId })
        {
            currentURL = session.url
            pageTitle = session.title
            return
        }

        if let first = sessions.first {
            activeSessionId = first.id
            currentURL = first.url
            pageTitle = first.title
        } else {
            activeSessionId = nil
            currentURL = ""
            pageTitle = ""
        }
    }

    private func persistSession(_ session: BrowserSession) {
        do {
            try databaseManager.saveBrowserSession(session)
        } catch {
            NSLog("threadmill-browser: failed to save browser session %@: %@", session.id, "\(error)")
        }
    }

    private func persistSessionOrder() {
        for (index, session) in sessions.enumerated() {
            guard session.order != index else {
                continue
            }

            var reordered = session
            reordered.order = index
            sessions[index] = reordered
            persistSession(reordered)
        }
    }

    private func resetNavigationState() {
        canGoBack = false
        canGoForward = false
        isLoading = false
        loadingProgress = 0
    }

    private static func defaultURL(portOffset: Int?) -> String {
        let offset = max(0, portOffset ?? 0)
        return "http://localhost:\(3000 + offset)"
    }

    var debugSummary: String {
        debugSnapshot.summary
    }

    var debugSnapshot: DebugSnapshot {
        DebugSnapshot(
            sessionCount: sessions.count,
            activeSessionID: activeSessionId,
            currentURL: currentURL,
            pageTitle: pageTitle,
            isLoading: isLoading,
            loadingProgress: loadingProgress,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            loadError: loadError
        )
    }
}
