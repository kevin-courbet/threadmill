import SwiftUI

struct AddProjectSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var path = ""
    @State private var browseResults: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Project")
                .font(.title3.weight(.semibold))

            Form {
                Text("Remote path on your development machine (beast).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Path on beast", text: $path, prompt: Text("/home/wsl/dev/myproject"))
                    .accessibilityIdentifier("sheet.add-project.path-input")
                    .accessibilityLabel("Sheet Add Project Path")

                Button("Browse") {
                    Task {
                        await browse()
                    }
                }
                .accessibilityIdentifier("sheet.add-project.browse-button")
                .accessibilityLabel("Sheet Add Project Browse")

                if !browseResults.isEmpty {
                    Picker("Directories", selection: $path) {
                        ForEach(browseResults, id: \.self) { candidate in
                            Text(candidate).tag(candidate)
                        }
                    }
                    .accessibilityIdentifier("sheet.add-project.directories-picker")
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
                .accessibilityIdentifier("sheet.add-project.cancel-button")
                .accessibilityLabel("Sheet Add Project Cancel")
                Button("Add") {
                    Task {
                        await addProject()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                .accessibilityIdentifier("sheet.add-project.submit-button")
                .accessibilityLabel("Sheet Add Project Submit")
            }
        }
        .padding(16)
        .frame(width: 520)
        .accessibilityIdentifier("sheet.add-project")
    }

    private func browse() async {
        isLoading = true
        defer { isLoading = false }

        do {
            errorMessage = nil
            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            let browsePath = trimmedPath.isEmpty ? "/home/wsl/dev" : trimmedPath
            browseResults = try await appState.browseDirectories(path: browsePath)
            if trimmedPath.isEmpty {
                path = browsePath
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addProject() async {
        isLoading = true
        defer { isLoading = false }

        do {
            errorMessage = nil
            try await appState.addProject(path: path)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
