import SwiftUI

struct CloneRepoSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var repositoryURL = ""
    @State private var clonePath = "/home/wsl/dev/"
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone Repository")
                .font(.title3.weight(.semibold))

            Form {
                Text("Clone a repository on beast and register it as a project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Repository URL", text: $repositoryURL, prompt: Text("https://github.com/org/repo.git"))
                    .accessibilityIdentifier("sheet.clone-repo.url-input")
                    .accessibilityLabel("Sheet Clone Repo URL")

                TextField("Clone path", text: $clonePath, prompt: Text("/home/wsl/dev/"))
                    .accessibilityIdentifier("sheet.clone-repo.path-input")
                    .accessibilityLabel("Sheet Clone Repo Path")

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
                .disabled(isLoading)
                .accessibilityIdentifier("sheet.clone-repo.cancel-button")
                .accessibilityLabel("Sheet Clone Repo Cancel")

                Button(isLoading ? "Cloning..." : "Clone") {
                    Task {
                        await cloneRepo()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                .accessibilityIdentifier("sheet.clone-repo.submit-button")
                .accessibilityLabel("Sheet Clone Repo Submit")
            }
        }
        .padding(16)
        .frame(width: 520)
        .accessibilityIdentifier("sheet.clone-repo")
    }

    private func cloneRepo() async {
        isLoading = true
        defer { isLoading = false }

        do {
            errorMessage = nil
            let trimmedURL = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPath = clonePath.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = trimmedPath.isEmpty ? nil : trimmedPath
            try await appState.cloneRepo(url: trimmedURL, path: path)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
