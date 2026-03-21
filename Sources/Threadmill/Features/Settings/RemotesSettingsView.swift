import SwiftUI

struct RemotesSettingsView: View {
    private struct RemoteEditorContext: Identifiable {
        enum Mode {
            case add
            case edit
        }

        let mode: Mode
        let remote: Remote

        var id: String {
            switch mode {
            case .add:
                return "add"
            case .edit:
                return remote.id
            }
        }

        var title: String {
            switch mode {
            case .add:
                return "Add Remote"
            case .edit:
                return "Edit Remote"
            }
        }

        var saveButtonTitle: String {
            switch mode {
            case .add:
                return "Add"
            case .edit:
                return "Save"
            }
        }
    }

    let databaseManager: (any DatabaseManaging)?
    let appState: AppState

    @State private var editorContext: RemoteEditorContext?
    @State private var remotePendingDeletion: Remote?
    @State private var errorMessage: String?

    private var sortedRemotes: [Remote] {
        appState.remotes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Configured Remotes") {
                if databaseManager == nil {
                    Text("Remote settings are unavailable until the database is initialized.")
                        .foregroundStyle(.secondary)
                } else if sortedRemotes.isEmpty {
                    Text("No remotes configured yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedRemotes) { remote in
                        remoteRow(remote)
                    }
                }

                Button {
                    editorContext = RemoteEditorContext(mode: .add, remote: defaultRemoteDraft())
                } label: {
                    Label("Add Remote", systemImage: "plus")
                }
                .disabled(databaseManager == nil)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            appState.reloadFromDatabase()
        }
        .sheet(item: $editorContext) { context in
            RemoteEditorSheet(
                initialRemote: context.remote,
                title: context.title,
                saveButtonTitle: context.saveButtonTitle
            ) { remote in
                persist(remote)
            }
        }
        .alert(
            "Delete Remote?",
            isPresented: Binding(
                get: { remotePendingDeletion != nil },
                set: { shouldShow in
                    if !shouldShow {
                        remotePendingDeletion = nil
                    }
                }
            ),
            presenting: remotePendingDeletion
        ) { remote in
            Button("Cancel", role: .cancel) {
                remotePendingDeletion = nil
            }
            Button("Delete", role: .destructive) {
                delete(remote)
            }
        } message: { remote in
            Text("Remove \(remote.name) from configured remotes?")
        }
    }

    @ViewBuilder
    private func remoteRow(_ remote: Remote) -> some View {
        let status = connectionStatus(for: remote)

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(remote.name)
                    .fontWeight(.semibold)
                Text("\(remote.host):\(remote.daemonPort)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(remote.cloneRoot)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Edit") {
                editorContext = RemoteEditorContext(mode: .edit, remote: remote)
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                remotePendingDeletion = remote
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(isProtectedRemote(remote))
            .help(isProtectedRemote(remote) ? "The default remote cannot be deleted." : "Delete remote")
        }
        .padding(.vertical, 4)
    }

    private func connectionStatus(for remote: Remote) -> (label: String, color: Color) {
        guard appState.activeRemoteID == remote.id else {
            return ("Idle", .gray.opacity(0.7))
        }

        switch appState.connectionStatus {
        case .connected:
            return ("Connected", .green)
        case .connecting:
            return ("Connecting", .orange)
        case .reconnecting:
            return ("Reconnecting", .orange)
        case .disconnected:
            return ("Disconnected", .gray)
        }
    }

    private func defaultRemoteDraft() -> Remote {
        Remote(
            id: UUID().uuidString,
            name: "",
            host: "",
            daemonPort: DatabaseManager.RemoteDefaults.beastDaemonPort,
            useSSHTunnel: true,
            cloneRoot: DatabaseManager.RemoteDefaults.beastCloneRoot,
            isDefault: false
        )
    }

    private func isProtectedRemote(_ remote: Remote) -> Bool {
        remote.isDefault
    }

    private func persist(_ remote: Remote) {
        guard let databaseManager else {
            return
        }

        if hasDuplicateName(remote) {
            errorMessage = "A remote named \"\(remote.name)\" already exists."
            return
        }

        do {
            errorMessage = nil
            try databaseManager.saveRemote(remote)
            appState.reloadFromDatabase()
            editorContext = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func hasDuplicateName(_ remote: Remote) -> Bool {
        appState.remotes.contains { existing in
            existing.id != remote.id
                && existing.name.localizedCaseInsensitiveCompare(remote.name) == .orderedSame
        }
    }

    private func delete(_ remote: Remote) {
        guard let databaseManager else {
            return
        }

        if isProtectedRemote(remote) {
            errorMessage = "The default remote cannot be deleted."
            remotePendingDeletion = nil
            return
        }

        do {
            errorMessage = nil
            try databaseManager.deleteRemote(id: remote.id)
            appState.reloadFromDatabase()
            remotePendingDeletion = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RemoteEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Remote

    let title: String
    let saveButtonTitle: String
    let onSave: (Remote) -> Void

    init(initialRemote: Remote, title: String, saveButtonTitle: String, onSave: @escaping (Remote) -> Void) {
        _draft = State(initialValue: initialRemote)
        self.title = title
        self.saveButtonTitle = saveButtonTitle
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.cloneRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.daemonPort > 0
            && draft.daemonPort <= 65_535
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Connection") {
                    TextField("Name", text: $draft.name)
                    TextField("Host", text: $draft.host)
                    TextField("Daemon Port", value: $draft.daemonPort, format: .number)
                    Toggle("Use SSH Tunnel", isOn: $draft.useSSHTunnel)
                }

                Section("Paths") {
                    TextField("Clone Root", text: $draft.cloneRoot)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button(saveButtonTitle) {
                    onSave(normalized(remote: draft))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 480, height: 320)
        .navigationTitle(title)
    }

    private func normalized(remote: Remote) -> Remote {
        Remote(
            id: remote.id,
            name: remote.name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: remote.host.trimmingCharacters(in: .whitespacesAndNewlines),
            daemonPort: remote.daemonPort,
            useSSHTunnel: remote.useSSHTunnel,
            cloneRoot: remote.cloneRoot.trimmingCharacters(in: .whitespacesAndNewlines),
            isDefault: remote.isDefault
        )
    }
}
