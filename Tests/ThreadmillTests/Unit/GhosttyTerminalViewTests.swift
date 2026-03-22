import XCTest
@testable import Threadmill

@MainActor
final class GhosttyTerminalViewTests: XCTestCase {
    func testCoordinatorUnmountsOldEndpointBeforeMountingNewEndpoint() {
        let recorder = EndpointLifecycleRecorder()
        let oldEndpoint = TrackingTerminalEndpoint(id: "old", recorder: recorder)
        let newEndpoint = TrackingTerminalEndpoint(id: "new", recorder: recorder)
        let view = GhosttyNSView(frame: .zero)

        oldEndpoint.mount(on: view)
        let coordinator = GhosttyTerminalView.Coordinator(endpoint: oldEndpoint)
        coordinator.mount(endpoint: newEndpoint, on: view)

        XCTAssertEqual(recorder.events, ["old.mount", "old.unmount", "new.mount"])
    }
}

@MainActor
private final class EndpointLifecycleRecorder {
    var events: [String] = []
}

@MainActor
private final class TrackingTerminalEndpoint: TerminalViewEndpoint {
    private let id: String
    private let recorder: EndpointLifecycleRecorder

    init(id: String, recorder: EndpointLifecycleRecorder) {
        self.id = id
        self.recorder = recorder
    }

    func mount(on _: GhosttyNSView) {
        recorder.events.append("\(id).mount")
    }

    func unmount(from _: GhosttyNSView) {
        recorder.events.append("\(id).unmount")
    }
}
