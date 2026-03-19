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
                if manager.sessions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "globe")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("No page loaded")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("Enter a URL or open a new tab")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    ForEach(manager.sessions) { session in
                        let isActive = session.id == manager.activeSessionId
                        WebViewWrapper(
                            url: session.url,
                            sessionID: session.id,
                            onNavigationStateChange: { canGoBack, canGoForward, isLoading, loadingProgress in
                                if session.id == manager.activeSessionId {
                                    manager.updateNavigationState(
                                        canGoBack: canGoBack,
                                        canGoForward: canGoForward,
                                        isLoading: isLoading,
                                        loadingProgress: loadingProgress
                                    )
                                }
                            },
                            onURLChange: { manager.handleURLChange(sessionID: session.id, url: $0) },
                            onTitleChange: { manager.handleTitleChange(sessionID: session.id, title: $0) },
                            onNewTab: { manager.createSession(url: $0) },
                            onWebViewCreated: { manager.registerWebView($0, for: session.id) },
                            onLoadError: { if isActive { manager.handleLoadError($0) } }
                        )
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                    }
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
        .overlay {
            DebugSnapshotWriter(name: "browser", value: manager.debugSnapshot)
        }
        .onAppear {
            if manager.sessions.isEmpty {
                manager.createSession()
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabBarIconButton(systemName: "chevron.left", isDisabled: previousSessionID == nil) {
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

            tabBarIconButton(systemName: "chevron.right", isDisabled: nextSessionID == nil) {
                if let nextSessionID {
                    manager.selectSession(nextSessionID)
                }
            }

            tabBarIconButton(systemName: "plus") {
                manager.createSession()
            }
            .help("New browser tab")
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func tab(_ session: BrowserSession) -> some View {
        let isSelected = manager.activeSessionId == session.id
        let isCloseVisible = isSelected || hoveredTabID == session.id

        return TabContainer(isSelected: isSelected, style: .topBorder) {
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

    private func tabBarIconButton(systemName: String, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        BrowserTabBarIconButton(systemName: systemName, isDisabled: isDisabled, action: action)
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

private struct BrowserTabBarIconButton: View {
    let systemName: String
    let isDisabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(isHovered ? Color(nsColor: .separatorColor).opacity(0.5) : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .onHover { isHovered = $0 }
    }
}
