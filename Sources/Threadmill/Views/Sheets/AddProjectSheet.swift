import SwiftUI

struct AddProjectSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var path = "/home/wsl/dev"
    @State private var browseResults: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Project")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Path on beast", text: $path)

                Button("Browse") {
                    Task {
                        await browse()
                    }
                }

                if !browseResults.isEmpty {
                    Picker("Directories", selection: $path) {
                        ForEach(browseResults, id: \.self) { candidate in
                            Text(candidate).tag(candidate)
                        }
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
                Button("Add") {
                    Task {
                        await addProject()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func browse() async {
        isLoading = true
        defer { isLoading = false }

        do {
            errorMessage = nil
            browseResults = try await appState.browseDirectories(path: path)
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
