import AppKit
import GhosttyKit
import os

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
            Logger.ghostty.error("threadmill-relay binary not found")
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

        Logger.ghostty.info("relay=\(relayPath, privacy: .public)")

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
            Logger.ghostty.info("Freeing \(self.activeSurfaces.count) active ghostty surfaces before shutdown")
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
        loadThemeDefaults(into: config)
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

    private func loadThemeDefaults(into config: ghostty_config_t) {
        guard let filePath = writeThemeDefaultsFile() else {
            Logger.ghostty.error("Failed to write ghostty theme defaults")
            return
        }

        filePath.withCString { ptr in
            ghostty_config_load_file(config, ptr)
        }
    }

    private func writeThemeDefaultsFile() -> String? {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threadmill", isDirectory: true)
        let fileURL = baseDirectory.appendingPathComponent("ghostty-default-theme.ghostty")

        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

            let existing = try? String(contentsOf: fileURL, encoding: .utf8)
            if existing != Self.themeDefaults {
                try Self.themeDefaults.write(to: fileURL, atomically: true, encoding: .utf8)
            }

            return fileURL.path
        } catch {
            Logger.ghostty.error("Unable to persist ghostty theme defaults: \(error)")
            return nil
        }
    }

    private static let themeDefaults = """
    background = #1e1e2e
    foreground = #cdd6f4

    palette = 0=#45475a
    palette = 1=#f38ba8
    palette = 2=#a6e3a1
    palette = 3=#f9e2af
    palette = 4=#89b4fa
    palette = 5=#f5c2e7
    palette = 6=#94e2d5
    palette = 7=#bac2de
    palette = 8=#585b70
    palette = 9=#f38ba8
    palette = 10=#a6e3a1
    palette = 11=#f9e2af
    palette = 12=#89b4fa
    palette = 13=#f5c2e7
    palette = 14=#94e2d5
    palette = 15=#a6adc8
    """

    private func handleChildExited(target: ghostty_target_s) {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else {
            Logger.ghostty.info("Child exited for unknown surface")
            return
        }
        guard let endpoint = endpointBySurface[surface]?.value else {
            Logger.ghostty.info("Child exited for unregistered surface")
            return
        }
        Logger.ghostty.info("Child exited for endpoint \(endpoint.threadID)/\(endpoint.preset)")
        endpoint.relayChildExited(surface: surface)
    }

    private func handleCloseSurface(userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let userdata,
              let surface = surfaceByUserdata[userdata] else {
            Logger.ghostty.info("close_surface callback without registered userdata")
            return
        }

        let endpoint = endpointBySurface[surface]?.value
        if let endpoint {
            Logger.ghostty.info("Closing surface for endpoint \(endpoint.threadID)/\(endpoint.preset) process_alive=\(processAlive)")
        } else {
            Logger.ghostty.info("Closing unregistered surface process_alive=\(processAlive)")
        }

        freeSurface(surface)
        endpoint?.surfaceClosed(surface, processAlive: processAlive)
    }
}
