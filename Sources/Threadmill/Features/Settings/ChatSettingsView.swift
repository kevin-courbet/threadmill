import SwiftUI

struct ChatSettingsView: View {
    private struct GitHubUser: Decodable {
        let login: String
    }

    let gitHubAuthManager: GitHubAuthManager

    @AppStorage("threadmill.chat.default-model") private var defaultModel = "auto"

    @State private var gitHubUsername: String?
    @State private var isAuthenticating = false
    @State private var isLoadingUsername = false
    @State private var authError: String?

    var body: some View {
        Form {
            Section("GitHub") {
                if gitHubAuthManager.isAuthenticated {
                    if let gitHubUsername {
                        Text("Connected as @\(gitHubUsername)")
                    } else if isLoadingUsername {
                        ProgressView("Loading account...")
                    } else {
                        Text("Connected")
                    }

                    Button("Sign Out") {
                        gitHubAuthManager.logout()
                        gitHubUsername = nil
                        authError = nil
                    }
                } else {
                    Text("Not connected")
                        .foregroundStyle(.secondary)

                    Button("Sign In") {
                        Task {
                            await signIn()
                        }
                    }
                    .disabled(isAuthenticating)
                }

                if let code = gitHubAuthManager.userCode {
                    Text("Authorization code: \(code)")
                        .font(.system(.body, design: .monospaced))
                }

                if let authError {
                    Text(authError)
                        .foregroundStyle(.red)
                }
            }

            Section("AI") {
                Picker("Default Model", selection: $defaultModel) {
                    Text("Auto").tag("auto")
                }
                Text("Model and provider preferences will be expanded in a future update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await loadStoredSession()
        }
    }

    @MainActor
    private func loadStoredSession() async {
        if !gitHubAuthManager.isAuthenticated {
            _ = gitHubAuthManager.loadStoredToken()
        }

        guard gitHubAuthManager.isAuthenticated else {
            gitHubUsername = nil
            return
        }

        await loadGitHubUsername()
    }

    @MainActor
    private func signIn() async {
        isAuthenticating = true
        authError = nil
        defer { isAuthenticating = false }

        do {
            try await gitHubAuthManager.startDeviceFlow()
            await loadGitHubUsername()
        } catch {
            authError = error.localizedDescription
        }
    }

    @MainActor
    private func loadGitHubUsername() async {
        guard let token = gitHubAuthManager.currentToken(), !token.isEmpty else {
            gitHubUsername = nil
            return
        }

        isLoadingUsername = true
        defer { isLoadingUsername = false }

        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
            request.httpMethod = "GET"
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode)
            else {
                throw GitHubClientError.invalidResponse
            }

            let user = try JSONDecoder().decode(GitHubUser.self, from: data)
            gitHubUsername = user.login
            authError = nil
        } catch {
            gitHubUsername = nil
            authError = error.localizedDescription
        }
    }
}
