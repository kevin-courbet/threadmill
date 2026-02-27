import XCTest
@testable import Threadmill

final class TerminalTabBarTests: XCTestCase {
    func testPreferredPresetToStartUsesTerminalBeforeFirstAvailable() {
        let presets = [
            Preset(name: "opencode", label: "Opencode"),
            Preset(name: "terminal", label: "Terminal"),
            Preset(name: "logs", label: "Logs"),
        ]

        XCTAssertEqual(preferredPresetToStart(from: presets)?.name, "terminal")
        XCTAssertEqual(preferredPresetToStart(from: [Preset(name: "logs", label: "Logs")])?.name, "logs")
        XCTAssertNil(preferredPresetToStart(from: []))
    }
}
