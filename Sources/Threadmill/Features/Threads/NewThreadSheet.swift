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

private enum NewThreadTarget {
    case repo(Repo)
    case project(Project)
}

struct NewThreadSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private let target: NewThreadTarget

    @State private var selectedRemoteID: String?
    @State private var name = ""
    @State private var sourceType: NewThreadSourceType = .newFeature
    @State private var selectedBranch = ""
    @State private var prURL = ""
    @State private var branches: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(repo: Repo) {
        target = .repo(repo)
    }

    init(project: Project) {
        target = .project(project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Thread")
                .font(.title3.weight(.semibold))

            Form {
                if let targetRepo {
                    LabeledContent("Repository") {
                        Text(targetRepo.fullName)
                    }

                    Picker("Remote", selection: $selectedRemoteID) {
                        ForEach(appState.remotes) { remote in
                            Text(remote.name).tag(Optional(remote.id))
                        }
                    }
                    .accessibilityIdentifier("sheet.new-thread.remote-picker")
                    .accessibilityLabel("Sheet New Thread Remote")
                }

                if let targetProject {
                    LabeledContent("Project") {
                        Text(targetProject.name)
                    }
                }

                TextField("Thread name", text: $name)
                    .accessibilityIdentifier("sheet.new-thread.name-input")
                    .accessibilityLabel("Sheet New Thread Name")

                if shouldShowSourcePicker {
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
            guard targetRepo != nil else {
                return
            }
            selectedRemoteID = selectedRemoteID ?? appState.selectedWorkspaceRemoteID ?? appState.remotes.first?.id
        }
        .onChange(of: selectedRemoteID) { _, _ in
            guard targetRepo != nil else {
                return
            }
            branches = []
            selectedBranch = ""
            if sourceType == .existingBranch {
                Task {
                    await loadBranches()
                }
            }
        }
    }

    private var shouldShowSourcePicker: Bool {
        switch target {
        case .repo(let repo):
            return !repo.isDefaultWorkspace
        case .project:
            return true
        }
    }

    private var isCreateDisabled: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !isLoading else {
            return true
        }

        if targetRepo != nil, selectedRemote == nil {
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
        isLoading = true
        defer { isLoading = false }

        do {
            errorMessage = nil

            let projectID: String
            switch target {
            case .repo(let repo):
                guard let remote = selectedRemote else {
                    return
                }
                if let existingProjectID = appState.projectId(for: repo, on: remote) {
                    projectID = existingProjectID
                } else {
                    projectID = try await appState.ensureRepoOnRemote(repo: repo, remote: remote)
                }
            case .project(let project):
                projectID = project.id
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

            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            switch target {
            case .repo(let repo):
                guard let remote = selectedRemote else {
                    return
                }
                try await appState.createThread(
                    repo: repo,
                    remote: remote,
                    name: trimmedName,
                    sourceType: sourceType.rawValue,
                    branch: branch,
                    prURL: prURL
                )
            case .project(let project):
                try await appState.createThread(
                    projectID: project.id,
                    name: trimmedName,
                    sourceType: sourceType.rawValue,
                    branch: branch,
                    prURL: prURL
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var preselectedRepo: Repo? {
        if case .repo(let repo) = target {
            return repo
        }
        return nil
    }

    private var targetRepo: Repo? {
        if case .repo(let repo) = target {
            return repo
        }
        return nil
    }

    private var targetProject: Project? {
        if case .project(let project) = target {
            return project
        }
        return nil
    }

    private var selectedRemote: Remote? {
        guard let selectedRemoteID else {
            return nil
        }
        return appState.remotes.first(where: { $0.id == selectedRemoteID })
    }
}
