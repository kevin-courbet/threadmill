import SwiftUI

struct BrowserView: View {
    @StateObject private var manager: BrowserSessionManager
    @State private var hoveredTabID: String?

    init(thread: ThreadModel, databaseManager: any DatabaseManaging) {
        _manager = StateObject(wrappedValue: BrowserSessionManager(databaseManager: databaseManager, thread: thread))
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()

            BrowserControlBar(
                url: $manager.currentURL,
                canGoBack: manager.canGoBack,
                canGoForward: manager.canGoForward,
                isLoading: manager.isLoading,
                loadingProgress: manager.loadingProgress,
                onBack: { manager.goBack() },
                onForward: { manager.goForward() },
                onReload: { manager.reload() },
                onNavigate: { manager.navigateToURL($0) }
            )

            Divider()

            ZStack {
                if let activeSession = manager.activeSession {
                    WebViewWrapper(
                        url: activeSession.url,
                        onNavigationStateChange: { canGoBack, canGoForward, isLoading, loadingProgress in
                            manager.updateNavigationState(
                                canGoBack: canGoBack,
                                canGoForward: canGoForward,
                                isLoading: isLoading,
                                loadingProgress: loadingProgress
                            )
                        },
                        onURLChange: { manager.handleURLChange(sessionID: activeSession.id, url: $0) },
                        onTitleChange: { manager.handleTitleChange(sessionID: activeSession.id, title: $0) },
                        onNewTab: { manager.createSession(url: $0) },
                        onWebViewCreated: { manager.registerActiveWebView($0, for: activeSession.id) },
                        onLoadError: { manager.handleLoadError($0) }
                    )
                    .id(activeSession.id)
                } else {
                    ContentUnavailableView(
                        "No browser tabs",
                        systemImage: "globe",
                        description: Text("Create a tab to open the thread dev server.")
                    )
                }

                if let loadError = manager.loadError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.yellow)
                        Text("Failed to load page")
                            .font(.headline)
                        Text(loadError)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if manager.sessions.isEmpty {
                manager.createSession()
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            arrowButton(systemName: "chevron.left", isDisabled: previousSessionID == nil) {
                if let previousSessionID {
                    manager.selectSession(previousSessionID)
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(manager.sessions) { session in
                            tab(session)
                                .id(session.id)
                        }
                    }
                }
                .onAppear {
                    guard let activeSessionID = manager.activeSessionId else {
                        return
                    }
                    proxy.scrollTo(activeSessionID, anchor: .center)
                }
                .onChange(of: manager.activeSessionId) { _, next in
                    guard let next else {
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.16)) {
                        proxy.scrollTo(next, anchor: .center)
                    }
                }
            }

            arrowButton(systemName: "chevron.right", isDisabled: nextSessionID == nil) {
                if let nextSessionID {
                    manager.selectSession(nextSessionID)
                }
            }

            Button {
                manager.createSession()
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New browser tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 34)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func tab(_ session: BrowserSession) -> some View {
        let isSelected = manager.activeSessionId == session.id
        let isCloseVisible = isSelected || hoveredTabID == session.id

        return TabContainer(isSelected: isSelected) {
            manager.selectSession(session.id)
        } content: {
            HStack(spacing: 6) {
                TabLabel(title: tabTitle(for: session), icon: "globe")
                    .frame(maxWidth: 260)

                TabCloseButton {
                    manager.closeSession(session.id)
                }
                .opacity(isCloseVisible ? 1 : 0)
                .allowsHitTesting(isCloseVisible)
            }
        }
        .onHover { hovering in
            hoveredTabID = hovering ? session.id : nil
        }
    }

    private func arrowButton(systemName: String, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
                .frame(width: 18, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
    }

    private var selectedIndex: Int? {
        guard let activeSessionId = manager.activeSessionId else {
            return nil
        }
        return manager.sessions.firstIndex(where: { $0.id == activeSessionId })
    }

    private var previousSessionID: String? {
        guard let selectedIndex, selectedIndex > 0 else {
            return nil
        }
        return manager.sessions[selectedIndex - 1].id
    }

    private var nextSessionID: String? {
        guard let selectedIndex, selectedIndex + 1 < manager.sessions.count else {
            return nil
        }
        return manager.sessions[selectedIndex + 1].id
    }

    private func tabTitle(for session: BrowserSession) -> String {
        let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        if let host = URL(string: session.url)?.host, !host.isEmpty {
            return host
        }

        let trimmedURL = session.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty {
            return trimmedURL
        }

        return "New tab"
    }
}
