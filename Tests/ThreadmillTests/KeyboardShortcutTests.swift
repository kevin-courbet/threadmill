import XCTest
@testable import Threadmill

@MainActor
final class KeyboardShortcutTests: XCTestCase {
    func testShortcutActionsExistAndAreCallable() {
        let appState = AppState()

        appState.selectThreadByIndex(0)

        appState.openNewThreadSheet()
        XCTAssertTrue(appState.isNewThreadSheetPresented)

        appState.closeSelectedThread()

        appState.nextPresetTab()
        appState.previousPresetTab()

        appState.restartCurrentPreset()

        appState.toggleConnection()
    }
}
