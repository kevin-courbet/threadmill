import Foundation

struct TerminalTabModel: Identifiable {
    let threadID: String
    let preset: Preset
    let endpoint: RelayEndpoint?

    var id: String {
        "\(threadID)::\(preset.name)"
    }

    @MainActor var isAttached: Bool { endpoint?.channelID ?? 0 > 0 }
}
