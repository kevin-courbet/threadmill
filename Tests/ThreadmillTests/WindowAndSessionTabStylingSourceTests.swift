import Foundation
import XCTest

final class WindowAndSessionTabStylingSourceTests: XCTestCase {
    func testThreadmillAppUsesHiddenTitleBarWindowChrome() throws {
        let source = try loadSource(at: "Sources/Threadmill/App/ThreadmillApp.swift")

        XCTAssertTrue(source.contains(".windowStyle(.hiddenTitleBar)"))
        XCTAssertTrue(source.contains(".windowToolbarStyle(.unified)"))
    }

    func testModePickerUsesLocalizedLabelWithIcon() throws {
        let source = try loadSource(at: "Sources/Threadmill/Features/Threads/ThreadDetailView.swift")

        XCTAssertTrue(source.contains("Label(LocalizedStringKey(tab.localizedKey), systemImage: tab.icon)"))
        XCTAssertFalse(source.contains("HStack(spacing: 4)"))
    }

    func testTabItemUsesAizenIconAssignments() throws {
        let source = try loadSource(at: "Sources/Threadmill/Models/TabItem.swift")

        XCTAssertTrue(source.contains("static let chat = TabItem(id: \"chat\", localizedKey: \"Chat\", icon: \"message\")"))
        XCTAssertTrue(source.contains("static let terminal = TabItem(id: \"terminal\", localizedKey: \"Terminal\", icon: \"terminal\")"))
        XCTAssertTrue(source.contains("static let files = TabItem(id: \"files\", localizedKey: \"Files\", icon: \"folder\")"))
        XCTAssertTrue(source.contains("static let browser = TabItem(id: \"browser\", localizedKey: \"Browser\", icon: \"globe\")"))
    }

    func testSessionTabsUseCapsuleAndAizenContextMenus() throws {
        let source = try loadSource(at: "Sources/Threadmill/Views/Components/SessionTabsScrollView.swift")

        XCTAssertTrue(source.contains("in: Capsule()"))
        XCTAssertTrue(source.contains("xmark.circle.fill"))
        XCTAssertTrue(source.contains("Close All to the Left"))
        XCTAssertTrue(source.contains("Close All to the Right"))
        XCTAssertTrue(source.contains("Close Other Tabs"))
        XCTAssertTrue(source.contains("WheelScrollHandler"))
    }

    private func loadSource(at relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: sourcePath, encoding: .utf8)
    }
}
