import SwiftUI

@main
struct ThreadmillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState(statsPollingEnabled: true)
    @State private var gitHubAuthManager = GitHubAuthManager()
    @AppStorage("threadmill.appearance-mode") private var appearanceMode = "dark"

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "system":
            return nil
        case "light":
            return .light
        default:
            return .dark
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(gitHubAuthManager)
                .frame(minWidth: 1200, minHeight: 800)
                .preferredColorScheme(preferredColorScheme)
                .task {
                    _ = gitHubAuthManager.loadStoredToken()
                    appDelegate.bootstrap(appState: appState)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    SettingsWindowManager.shared.show(
                        appState: appState,
                        databaseManager: appState.databaseManager,
                        gitHubAuthManager: gitHubAuthManager
                    )
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
