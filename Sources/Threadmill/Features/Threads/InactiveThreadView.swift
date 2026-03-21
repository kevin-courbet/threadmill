import SwiftUI

struct InactiveThreadView: View {
    @Environment(AppState.self) private var appState

    let thread: ThreadModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: thread.status == .creating ? "hourglass" : "terminal")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(thread.status == .creating ? "Creating thread..." : "Thread is \(thread.status.rawValue)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if thread.status == .hidden {
                Button("Reopen") {
                    Task { await appState.reopenThread(threadID: thread.id) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
