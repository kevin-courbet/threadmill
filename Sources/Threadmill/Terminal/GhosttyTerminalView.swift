import SwiftUI

struct GhosttyTerminalView: NSViewRepresentable {
    let endpoint: RelayEndpoint

    func makeNSView(context: Context) -> GhosttyNSView {
        let view = GhosttyNSView(frame: .zero)
        endpoint.mount(on: view)
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: GhosttyNSView, context _: Context) {
        endpoint.mount(on: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(endpoint: endpoint)
    }

    static func dismantleNSView(_ nsView: GhosttyNSView, coordinator: Coordinator) {
        coordinator.endpoint.unmount(view: nsView)
    }

    final class Coordinator {
        let endpoint: RelayEndpoint
        weak var view: GhosttyNSView?

        init(endpoint: RelayEndpoint) {
            self.endpoint = endpoint
        }
    }
}
