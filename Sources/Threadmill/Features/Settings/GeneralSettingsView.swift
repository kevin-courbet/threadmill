import SwiftUI

enum ThreadmillAppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("threadmill.appearance-mode") private var appearanceMode = ThreadmillAppearanceMode.dark.rawValue
    @AppStorage("editorFontSize") private var editorFontSize: Double = 12
    @AppStorage("editorWrapLines") private var editorWrapLines = true
    @AppStorage("threadmill.show-chat-tab") private var showChatTab = true
    @AppStorage("threadmill.show-terminal-tab") private var showTerminalTab = true
    @AppStorage("threadmill.show-files-tab") private var showFilesTab = true
    @AppStorage("threadmill.show-browser-tab") private var showBrowserTab = true

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Color Scheme", selection: $appearanceMode) {
                    ForEach(ThreadmillAppearanceMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
            }

            Section("Editor") {
                HStack {
                    Text("Font Size")
                    Spacer()
                    Stepper(value: $editorFontSize, in: 10...24, step: 1) {
                        Text("\(Int(editorFontSize))")
                            .monospacedDigit()
                    }
                    .frame(width: 120)
                }

                Toggle("Wrap Lines", isOn: $editorWrapLines)
            }

            Section("Tabs") {
                Toggle("Chat", isOn: $showChatTab)
                Toggle("Terminal", isOn: $showTerminalTab)
                Toggle("Files", isOn: $showFilesTab)
                Toggle("Browser", isOn: $showBrowserTab)
            }
        }
        .formStyle(.grouped)
    }
}
