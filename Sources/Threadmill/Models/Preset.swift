import Foundation

struct Preset: Identifiable, Hashable, Codable {
    let name: String
    let label: String

    var id: String { name }

    init(name: String, label: String? = nil) {
        self.name = name
        self.label = label ?? Self.displayLabel(for: name)
    }

    static func displayLabel(for name: String) -> String {
        name
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    static let defaults: [Preset] = [
        Preset(name: "terminal", label: "Terminal"),
        Preset(name: "opencode", label: "Opencode")
    ]
}
