import SwiftUI

@main
struct ThreadmillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .task {
                    appDelegate.bootstrap(appState: appState)
                }
        }
    }
}
