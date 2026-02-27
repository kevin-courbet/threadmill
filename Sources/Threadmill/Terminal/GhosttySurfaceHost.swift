import AppKit
import GhosttyKit

@MainActor
final class GhosttySurfaceHost: SurfaceHosting {
    private final class WeakEndpoint {
        weak var value: RelayEndpoint?

        init(_ value: RelayEndpoint) {
            self.value = value
        }
    }

    private static weak var active: GhosttySurfaceHost?

    private var ghosttyApp: ghostty_app_t?
    private var ghosttyConfig: ghostty_config_t?
    private var endpointBySurface: [ghostty_surface_t: WeakEndpoint] = [:]
    private var surfaceByUserdata: [UnsafeMutableRawPointer: ghostty_surface_t] = [:]
    private var userdataBySurface: [ghostty_surface_t: UnsafeMutableRawPointer] = [:]
    private var activeSurfaces: Set<ghostty_surface_t> = []

    init() {
        GhosttySurfaceHost.active = self
        initializeGhostty()
    }

    func createSurface(in view: GhosttyNSView, socketPath: String) -> ghostty_surface_t? {
        guard let ghosttyApp else { return nil }
        guard let relayPath = relayBinaryPath() else {
            NSLog("threadmill: threadmill-relay binary not found")
            return nil
        }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque())
        )
        surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()
        let scaleFactor = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        surfaceConfig.scale_factor = Double(scaleFactor)

        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        defer {
            for (k, v) in envStorage {
                free(k)
                free(v)
            }
        }

        let env = ["THREADMILL_SOCKET": socketPath]
        for (key, value) in env {
            guard let k = strdup(key), let v = strdup(value) else { continue }
            envStorage.append((k, v))
            envVars.append(ghostty_env_var_s(key: k, value: v))
        }

        NSLog("threadmill: relay=%@", relayPath)

        var createdSurface: ghostty_surface_t?
        relayPath.withCString { cmdPtr in
            surfaceConfig.command = cmdPtr

            envVars.withUnsafeMutableBufferPointer { buffer in
                surfaceConfig.env_vars = buffer.baseAddress
                surfaceConfig.env_var_count = buffer.count
                createdSurface = ghostty_surface_new(ghosttyApp, &surfaceConfig)
            }
        }

        guard let surface = createdSurface else {
            return nil
        }

        activeSurfaces.insert(surface)
        if let userdata = surfaceConfig.userdata {
            surfaceByUserdata[userdata] = surface
            userdataBySurface[surface] = userdata
        }

        view.surface = surface
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let bounds = view.bounds
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(bounds.width * scale), UInt32(bounds.height * scale))
        ghostty_surface_set_focus(surface, true)

        if let screen = view.window?.screen ?? NSScreen.main,
           let displayID = screen.displayID {
            ghostty_surface_set_display_id(surface, displayID)
        }

        return surface
    }

    func freeSurface(_ surface: ghostty_surface_t?) {
        guard let surface else {
            return
        }
        unregister(surface: surface)
        ghostty_surface_free(surface)
    }

    func register(surface: ghostty_surface_t, for endpoint: RelayEndpoint) {
        endpointBySurface[surface] = WeakEndpoint(endpoint)
    }

    func unregister(surface: ghostty_surface_t) {
        endpointBySurface.removeValue(forKey: surface)
        activeSurfaces.remove(surface)
        if let userdata = userdataBySurface.removeValue(forKey: surface) {
            surfaceByUserdata.removeValue(forKey: userdata)
        }
    }

    func tick() {
        guard let ghosttyApp else {
            return
        }
        ghostty_app_tick(ghosttyApp)
    }

    func shutdown() {
        if !activeSurfaces.isEmpty {
            NSLog("threadmill: freeing %d active ghostty surfaces before shutdown", activeSurfaces.count)
            let surfaces = Array(activeSurfaces)
            for surface in surfaces {
                freeSurface(surface)
            }
        }

        if let ghosttyApp {
            ghostty_app_free(ghosttyApp)
            self.ghosttyApp = nil
        }
        if let ghosttyConfig {
            ghostty_config_free(ghosttyConfig)
            self.ghosttyConfig = nil
        }
    }

    private func relayBinaryPath() -> String? {
        RelayBinaryLocator.resolve()
    }

    private func initializeGhostty() {
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            fatalError("ghostty_init failed: \(result)")
        }

        guard let config = ghostty_config_new() else {
            fatalError("ghostty_config_new failed")
        }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        ghosttyConfig = config

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = nil
        runtimeConfig.supports_selection_clipboard = true

        runtimeConfig.wakeup_cb = { _ in
            DispatchQueue.main.async {
                GhosttySurfaceHost.active?.tick()
            }
        }

        runtimeConfig.action_cb = { _, target, action in
            if action.tag == GHOSTTY_ACTION_SHOW_CHILD_EXITED {
                DispatchQueue.main.async {
                    GhosttySurfaceHost.active?.handleChildExited(target: target)
                }
                return true
            }
            return false
        }

        runtimeConfig.read_clipboard_cb = { userdata, _, state in
            guard let userdata else { return }
            let view = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = view.surface else { return }
            let value = NSPasteboard.general.string(forType: .string) ?? ""
            value.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
        }

        runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let userdata, let content else { return }
            let view = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = view.surface else { return }
            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }

        runtimeConfig.write_clipboard_cb = { _, _, content, len, _ in
            guard let content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                return
            }
        }

        runtimeConfig.close_surface_cb = { userdata, processAlive in
            DispatchQueue.main.async {
                GhosttySurfaceHost.active?.handleCloseSurface(userdata: userdata, processAlive: processAlive)
            }
        }

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            fatalError("ghostty_app_new failed")
        }
        ghosttyApp = app
    }

    private func handleChildExited(target: ghostty_target_s) {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else {
            NSLog("threadmill: child exited for unknown surface")
            return
        }
        guard let endpoint = endpointBySurface[surface]?.value else {
            NSLog("threadmill: child exited for unregistered surface")
            return
        }
        NSLog("threadmill: child exited for endpoint %@/%@", endpoint.threadID, endpoint.preset)
        endpoint.relayChildExited(surface: surface)
    }

    private func handleCloseSurface(userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let userdata,
              let surface = surfaceByUserdata[userdata] else {
            NSLog("threadmill: close_surface callback without registered userdata")
            return
        }

        let endpoint = endpointBySurface[surface]?.value
        if let endpoint {
            NSLog(
                "threadmill: closing surface for endpoint %@/%@ process_alive=%d",
                endpoint.threadID,
                endpoint.preset,
                processAlive
            )
        } else {
            NSLog("threadmill: closing unregistered surface process_alive=%d", processAlive)
        }

        freeSurface(surface)
        endpoint?.surfaceClosed(surface, processAlive: processAlive)
    }
}
