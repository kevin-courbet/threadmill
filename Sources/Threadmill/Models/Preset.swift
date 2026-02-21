import Foundation

struct Preset: Identifiable, Hashable, Codable {
    let name: String
    let label: String

    var id: String { name }

    static let defaults: [Preset] = [
        Preset(name: "terminal", label: "Terminal"),
        Preset(name: "dev-server", label: "Dev Server")
    ]
}
