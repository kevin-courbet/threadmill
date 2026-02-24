import SwiftUI

@MainActor
protocol TerminalViewEndpoint: AnyObject {
    func mount(on view: GhosttyNSView)
    func unmount(from view: GhosttyNSView)
}

extension RelayEndpoint: TerminalViewEndpoint {}

struct GhosttyTerminalView: NSViewRepresentable {
    let endpoint: RelayEndpoint

    func makeNSView(context: Context) -> GhosttyNSView {
        let view = GhosttyNSView(frame: .zero)
        endpoint.mount(on: view)
        context.coordinator.endpoint = endpoint
        return view
    }

    func updateNSView(_ nsView: GhosttyNSView, context: Context) {
        context.coordinator.mount(endpoint: endpoint, on: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(endpoint: endpoint)
    }

    static func dismantleNSView(_ nsView: GhosttyNSView, coordinator: Coordinator) {
        coordinator.endpoint.unmount(from: nsView)
    }

    @MainActor
    final class Coordinator {
        var endpoint: any TerminalViewEndpoint

        init(endpoint: any TerminalViewEndpoint) {
            self.endpoint = endpoint
        }

        func mount(endpoint nextEndpoint: any TerminalViewEndpoint, on view: GhosttyNSView) {
            if ObjectIdentifier(endpoint as AnyObject) != ObjectIdentifier(nextEndpoint as AnyObject) {
                endpoint.unmount(from: view)
                nextEndpoint.mount(on: view)
                endpoint = nextEndpoint
                return
            }
            nextEndpoint.mount(on: view)
        }
    }
}
