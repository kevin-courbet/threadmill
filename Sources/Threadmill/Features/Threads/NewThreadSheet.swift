import SwiftUI

private enum NewThreadSourceType: String, CaseIterable, Identifiable {
    case newFeature = "new_feature"
    case existingBranch = "existing_branch"
    case pullRequest = "pull_request"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newFeature:
            return "New Feature"
        case .existingBranch:
            return "Existing Branch"
        case .pullRequest:
            return "PR URL"
        }
    }
}

struct NewThreadSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let repo: Repo

    @State private var selectedRemoteID: String?
    @State private var name = ""
    @State private var sourceType: NewThreadSourceType = .newFeature
    @State private var selectedBranch = ""
    @State private var prURL = ""
    @State private var branches: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Thread")
                .font(.title3.weight(.semibold))

            Form {
                LabeledContent("Repository") {
                    Text(repo.fullName)
                }

                Picker("Remote", selection: $selectedRemoteID) {
                    ForEach(appState.remotes) { remote in
                        Text(remote.name).tag(Optional(remote.id))
                    }
                }
                .accessibilityIdentifier("sheet.new-thread.remote-picker")
                .accessibilityLabel("Sheet New Thread Remote")

                TextField("Thread name", text: $name)
                    .accessibilityIdentifier("sheet.new-thread.name-input")
                    .accessibilityLabel("Sheet New Thread Name")

                Picker("Source", selection: $sourceType) {
                    ForEach(NewThreadSourceType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .accessibilityIdentifier("sheet.new-thread.source-picker")
                .accessibilityLabel("Sheet New Thread Source")

                if sourceType == .existingBranch {
                    if branches.isEmpty {
                        Button("Load Branches") {
                            Task {
                                await loadBranches()
                            }
                        }
                    }

                    Picker("Branch", selection: $selectedBranch) {
                        ForEach(branches, id: \.self) { branch in
                            Text(branch).tag(branch)
                        }
                    }
                    .accessibilityIdentifier("sheet.new-thread.branch-picker")
                    .accessibilityLabel("Sheet New Thread Branch")
                }

                if sourceType == .pullRequest {
                    TextField("PR URL", text: $prURL)
                        .accessibilityIdentifier("sheet.new-thread.pr-url-input")
                        .accessibilityLabel("Sheet New Thread PR URL")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .accessibilityIdentifier("sheet.new-thread.cancel-button")
                .accessibilityLabel("Sheet New Thread Cancel")
                Button("Create") {
                    Task {
                        await createThread()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreateDisabled)
                .accessibilityIdentifier("sheet.new-thread.submit-button")
                .accessibilityLabel("Sheet New Thread Submit")
            }
        }
        .padding(16)
        .frame(width: 520)
        .accessibilityIdentifier("sheet.new-thread")
        .onAppear {
            selectedRemoteID = selectedRemoteID ?? appState.remotes.first?.id
        }
        .onChange(of: selectedRemoteID) { _, _ in
            branches = []
            selectedBranch = ""
            if sourceType == .existingBranch {
                Task {
                    await loadBranches()
                }
            }
        }
    }

    private var isCreateDisabled: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, selectedRemote != nil, !isLoading else {
            return true
        }
        switch sourceType {
        case .newFeature:
            return false
        case .existingBranch:
            return selectedBranch.isEmpty
        case .pullRequest:
            return prURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func loadBranches() async {
        guard let remote = selectedRemote else {
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            errorMessage = nil
            let projectID: String
            if let existingProjectID = appState.projectId(for: repo, on: remote) {
                projectID = existingProjectID
            } else {
                projectID = try await appState.ensureRepoOnRemote(repo: repo, remote: remote)
            }
            branches = try await appState.branches(for: projectID)
            if selectedBranch.isEmpty {
                selectedBranch = branches.first ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createThread() async {
        guard let remote = selectedRemote else {
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            errorMessage = nil
            let branch: String?
            let prURL: String?
            switch sourceType {
            case .newFeature:
                branch = nil
                prURL = nil
            case .existingBranch:
                branch = selectedBranch
                prURL = nil
            case .pullRequest:
                branch = nil
                prURL = self.prURL
            }

            try await appState.createThread(
                repo: repo,
                remote: remote,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceType: sourceType.rawValue,
                branch: branch,
                prURL: prURL
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var selectedRemote: Remote? {
        guard let selectedRemoteID else {
            return nil
        }
        return appState.remotes.first(where: { $0.id == selectedRemoteID })
    }
}
