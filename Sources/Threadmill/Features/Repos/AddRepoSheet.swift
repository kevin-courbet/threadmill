import SwiftUI

struct AddRepoSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let authManager: GitHubAuthManager
    @State private var gitHubClient: GitHubClient?
    @State private var repos: [GitHubRepo] = []
    @State private var selectedRepoIDs: Set<Int> = []
    @State private var searchText = ""
    @State private var isLoadingRepos = false
    @State private var isConnecting = false
    @State private var errorMessage: String?

    private let dateFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        @Bindable var auth = authManager

        VStack(alignment: .leading, spacing: 12) {
            Text("Add Repository")
                .font(.title3.weight(.semibold))

            if !auth.isAuthenticated {
                unauthenticatedContent
            } else if isLoadingRepos {
                ProgressView("Loading repositories...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                authenticatedContent
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .accessibilityIdentifier("sheet.add-repo.cancel-button")

                Button("Add Selected") {
                    Task {
                        await saveSelectedRepos()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRepoIDs.isEmpty || isLoadingRepos)
                .accessibilityIdentifier("sheet.add-repo.submit-button")
            }
        }
        .padding(16)
        .frame(width: 760, height: 560)
        .accessibilityIdentifier("sheet.add-repo")
        .onAppear {
            Task {
                await restoreSessionIfAvailable()
            }
        }
    }

    private var unauthenticatedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect your GitHub account to browse repositories.")
                .foregroundStyle(.secondary)

            Button("Connect GitHub") {
                Task {
                    await startDeviceFlow()
                }
            }
            .disabled(isConnecting)
            .accessibilityIdentifier("sheet.add-repo.connect-github-button")

            if let code = authManager.userCode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Enter this code on GitHub:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(code)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                    if let verificationURL = authManager.verificationURL {
                        Link("Open verification page", destination: verificationURL)
                            .font(.caption)
                    }
                }
                .padding(.top, 4)
            }

            if authManager.isPolling {
                ProgressView("Waiting for GitHub authorization...")
                    .padding(.top, 4)
            }

            Spacer()
        }
    }

    private var authenticatedContent: some View {
        List {
            ForEach(groupedOwners, id: \.self) { owner in
                Section(owner) {
                    ForEach(reposByOwner[owner] ?? [], id: \.id) { repo in
                        Button {
                            toggleSelection(repoID: repo.id)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selectedRepoIDs.contains(repo.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedRepoIDs.contains(repo.id) ? Color.accentColor : .secondary)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(repo.name)
                                            .font(.system(size: 13, weight: .semibold))
                                        if repo.isPrivate {
                                            Text("Private")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                        }
                                    }

                                    Text(repo.fullName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    if let description = repo.description, !description.isEmpty {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }

                                Spacer(minLength: 12)

                                if let pushed = formatPushedDate(repo.pushedAt) {
                                    Text(pushed)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search repositories")
        .accessibilityIdentifier("sheet.add-repo.list")
    }

    private var filteredRepos: [GitHubRepo] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return repos
        }

        return repos.filter { repo in
            repo.fullName.localizedCaseInsensitiveContains(trimmedQuery)
                || repo.name.localizedCaseInsensitiveContains(trimmedQuery)
                || (repo.description?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }
    }

    private var reposByOwner: [String: [GitHubRepo]] {
        Dictionary(grouping: filteredRepos, by: { $0.owner.login })
            .mapValues { ownerRepos in
                ownerRepos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
    }

    private var groupedOwners: [String] {
        reposByOwner.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func startDeviceFlow() async {
        isConnecting = true
        defer { isConnecting = false }

        do {
            errorMessage = nil
            try await authManager.startDeviceFlow()
            prepareClient()
            await loadRepos()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareClient() {
        let manager = authManager
        guard manager.currentToken()?.isEmpty == false else {
            gitHubClient = nil
            return
        }
        gitHubClient = GitHubClient(tokenProvider: { manager.currentToken() }, onUnauthorized: {
            manager.logout()
        })
    }

    private func restoreSessionIfAvailable() async {
        guard authManager.loadStoredToken() else {
            return
        }

        prepareClient()
        guard let gitHubClient else {
            return
        }

        let isTokenValid = await gitHubClient.validateToken()
        guard isTokenValid else {
            authManager.logout()
            self.gitHubClient = nil
            repos = []
            selectedRepoIDs = []
            return
        }

        await loadRepos()
    }

    private func loadRepos() async {
        guard let gitHubClient else {
            return
        }

        isLoadingRepos = true
        defer { isLoadingRepos = false }

        do {
            errorMessage = nil
            repos = try await gitHubClient.fetchUserRepos()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveSelectedRepos() async {
        guard
            let databaseManager = appState.databaseManager,
            let gitHubClient
        else {
            errorMessage = "Database is unavailable."
            return
        }

        do {
            errorMessage = nil
            let selectedRepos = repos.filter { selectedRepoIDs.contains($0.id) }
            let existingRepoIDByFullName = Dictionary(uniqueKeysWithValues: appState.repos.map { ($0.fullName, $0.id) })
            let cachedAt = Date()

            for repo in selectedRepos {
                let mappedRepo = gitHubClient.mapToRepo(
                    repo,
                    existingID: existingRepoIDByFullName[repo.fullName],
                    cachedAt: cachedAt
                )
                try databaseManager.saveRepo(mappedRepo)
            }

            appState.reloadFromDatabase()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleSelection(repoID: Int) {
        if selectedRepoIDs.contains(repoID) {
            selectedRepoIDs.remove(repoID)
        } else {
            selectedRepoIDs.insert(repoID)
        }
    }

    private func formatPushedDate(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let date = dateFormatterWithFractionalSeconds.date(from: value) ?? dateFormatter.date(from: value)
        guard let date else {
            return nil
        }

        return "Updated \(relativeDateFormatter.localizedString(for: date, relativeTo: Date()))"
    }
}
