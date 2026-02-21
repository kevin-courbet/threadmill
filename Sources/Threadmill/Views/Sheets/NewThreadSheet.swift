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

    @State private var selectedProjectID: String?
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
                Picker("Project", selection: $selectedProjectID) {
                    ForEach(appState.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }

                TextField("Thread name", text: $name)

                Picker("Source", selection: $sourceType) {
                    ForEach(NewThreadSourceType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }

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
                }

                if sourceType == .pullRequest {
                    TextField("PR URL", text: $prURL)
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
                Button("Create") {
                    Task {
                        await createThread()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreateDisabled)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            selectedProjectID = selectedProjectID ?? appState.projects.first?.id
        }
        .onChange(of: selectedProjectID) { _, _ in
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
        guard !trimmedName.isEmpty, selectedProjectID != nil, !isLoading else {
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
        guard let selectedProjectID else {
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            errorMessage = nil
            branches = try await appState.branches(for: selectedProjectID)
            if selectedBranch.isEmpty {
                selectedBranch = branches.first ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createThread() async {
        guard let selectedProjectID else {
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            errorMessage = nil
            let sourceRef: String?
            switch sourceType {
            case .newFeature:
                sourceRef = nil
            case .existingBranch:
                sourceRef = selectedBranch
            case .pullRequest:
                sourceRef = prURL
            }

            try await appState.createThread(
                projectID: selectedProjectID,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceType: sourceType.rawValue,
                sourceRef: sourceRef
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
