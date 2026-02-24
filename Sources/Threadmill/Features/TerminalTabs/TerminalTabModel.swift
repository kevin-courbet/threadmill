import Foundation

struct TerminalTabModel: Identifiable {
    let threadID: String
    let preset: Preset
    let endpoint: RelayEndpoint?

    var id: String {
        "\(threadID)::\(preset.name)"
    }

    var isAttached: Bool {
        endpoint != nil
    }
}
