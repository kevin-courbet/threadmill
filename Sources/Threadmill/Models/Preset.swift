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

    static func orderedByDefaultPriority(_ presets: [Preset]) -> [Preset] {
        let defaultOrder = defaults.map { $0.name.lowercased() }

        return presets
            .enumerated()
            .sorted { lhs, rhs in
                let lhsPriority = defaultOrder.firstIndex(of: lhs.element.name.lowercased()) ?? Int.max
                let rhsPriority = defaultOrder.firstIndex(of: rhs.element.name.lowercased()) ?? Int.max

                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
