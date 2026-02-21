import AppKit
import GhosttyKit

// MVP: libghostty surface → PTY shim relay → Unix socket → WebSocket → Spindle → tmux

@main
struct ThreadmillMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var ghosttyApp: ghostty_app_t?
    private var ghosttyConfig: ghostty_config_t?
    private var surface: ghostty_surface_t?
    private var surfaceView: GhosttyNSView!

    private let socketPath = "/tmp/threadmill-\(ProcessInfo.processInfo.processIdentifier).sock"
    private var relayBridge: RelayBridge!
    private let connectionManager = ConnectionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        relayBridge = RelayBridge(
            socketPath: socketPath,
            connectionManager: connectionManager
        )

        initGhostty()
        createWindow()

        // Start connection to beast, then create surface once connected
        relayBridge.onReady = { [weak self] in
            // Connection to Spindle established and terminal attached
        }

        Task {
            await startConnection()
        }

        createSurface()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func startConnection() async {
        NSLog("threadmill: starting SSH tunnel to beast")

        // Step 1: establish SSH tunnel (retry up to 3 times)
        var tunnelUp = false
        for attempt in 1...3 {
            do {
                try await connectionManager.tunnelManager.start()
                tunnelUp = true
                NSLog("threadmill: SSH tunnel established on attempt %d", attempt)
                break
            } catch {
                NSLog("threadmill: SSH tunnel attempt %d failed: %@", attempt, "\(error)")
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s between retries
            }
        }
        guard tunnelUp else {
            NSLog("threadmill: failed to establish SSH tunnel, running in local mode")
            return
        }

        // Step 2: connect WebSocket
        guard let url = URL(string: "ws://127.0.0.1:\(ThreadmillConfig.daemonPort)") else { return }
        connectionManager.webSocketClient.connect(to: url)
        NSLog("threadmill: WebSocket connecting to %@", url.absoluteString)

        // Step 3: verify with ping
        do {
            _ = try await connectionManager.request(method: "ping", timeout: 10)
            connectionManager.markConnected()
            NSLog("threadmill: connected to Spindle")
        } catch {
            NSLog("threadmill: ping failed: %@, running in local mode", "\(error)")
            return
        }

        // Step 4: register binary frame handler BEFORE attach so we catch the initial capture-pane dump
        relayBridge.start(channelID: 0) // temporary channel, updated after attach returns

        do {
            let result = try await connectionManager.request(
                method: "terminal.attach",
                params: ["session": "threadmill-test", "window": 0, "pane": 0],
                timeout: 10
            )
            guard let channelID = parseChannelID(from: result), channelID > 0 else {
                NSLog("threadmill: terminal.attach returned invalid channel_id: %@", "\(result)")
                return
            }
            relayBridge.setAttachedChannelID(channelID)
            NSLog("threadmill: attached to remote terminal, channel=%d", channelID)

            // Sync tmux pane size to match ghostty surface
            await syncTerminalSize()
        } catch {
            NSLog("threadmill: terminal.attach failed: %@, running in local mode", "\(error)")
        }
    }

    func syncTerminalSize() async {
        guard let surface else { return }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0 && size.rows > 0 else { return }
        NSLog("threadmill: syncing terminal size: %dx%d", size.columns, size.rows)
        do {
            _ = try await connectionManager.request(
                method: "terminal.resize",
                params: [
                    "session": "threadmill-test",
                    "window": 0,
                    "pane": 0,
                    "cols": Int(size.columns),
                    "rows": Int(size.rows),
                ],
                timeout: 5
            )
        } catch {
            NSLog("threadmill: terminal.resize failed: %@", "\(error)")
        }
    }

    private func parseChannelID(from result: Any) -> UInt16? {
        if let intValue = result as? Int { return UInt16(clamping: intValue) }
        if let dict = result as? [String: Any] {
            if let v = dict["channel_id"] as? Int { return UInt16(clamping: v) }
            if let s = dict["channel_id"] as? String, let v = UInt16(s) { return v }
        }
        return nil
    }

    private func initGhostty() {
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            fatalError("ghostty_init failed: \(result)")
        }

        guard let config = ghostty_config_new() else {
            fatalError("ghostty_config_new failed")
        }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        self.ghosttyConfig = config

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true

        runtimeConfig.wakeup_cb = { _ in
            DispatchQueue.main.async {
                guard let delegate = NSApp.delegate as? AppDelegate,
                      let app = delegate.ghosttyApp else { return }
                ghostty_app_tick(app)
            }
        }

        runtimeConfig.action_cb = { _, _, action in
            if action.tag == GHOSTTY_ACTION_SHOW_CHILD_EXITED {
                NSLog("threadmill: child exited, terminating")
                DispatchQueue.main.async { NSApp.terminate(nil) }
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

        runtimeConfig.close_surface_cb = { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            fatalError("ghostty_app_new failed")
        }
        self.ghosttyApp = app
    }

    private func createWindow() {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Threadmill"
        window.center()
    }

    private func createSurface() {
        guard let ghosttyApp else { return }

        let view = GhosttyNSView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        view.appDelegate = self
        window.contentView!.addSubview(view)
        self.surfaceView = view

        // Find the relay binary next to our own executable
        let relayPath = relayBinaryPath()

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque())
        )
        surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.scale_factor = window.backingScaleFactor

        // Set the relay as the surface command + pass socket path via env
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        defer {
            for (k, v) in envStorage {
                free(k); free(v)
            }
        }

        let env = ["THREADMILL_SOCKET": socketPath]
        for (key, value) in env {
            guard let k = strdup(key), let v = strdup(value) else { continue }
            envStorage.append((k, v))
            envVars.append(ghostty_env_var_s(key: k, value: v))
        }

        NSLog("threadmill: relay=%@", relayPath)

        relayPath.withCString { cmdPtr in
            surfaceConfig.command = cmdPtr

            envVars.withUnsafeMutableBufferPointer { buffer in
                surfaceConfig.env_vars = buffer.baseAddress
                surfaceConfig.env_var_count = buffer.count

                let s = ghostty_surface_new(ghosttyApp, &surfaceConfig)
                guard let s else {
                    fatalError("ghostty_surface_new failed")
                }
                self.surface = s
                view.surface = s
            }
        }

        guard let s = surface else { return }

        let scale = window.backingScaleFactor
        let bounds = view.bounds
        ghostty_surface_set_content_scale(s, scale, scale)
        ghostty_surface_set_size(s, UInt32(bounds.width * scale), UInt32(bounds.height * scale))
        ghostty_surface_set_focus(s, true)

        if let screen = window.screen ?? NSScreen.main,
           let displayID = screen.displayID {
            ghostty_surface_set_display_id(s, displayID)
        }

        window.makeKeyAndOrderFront(nil)
    }

    private func relayBinaryPath() -> String {
        // In SPM debug builds, both binaries are in .build/debug/
        let selfURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
        let dir = selfURL.deletingLastPathComponent()
        let candidate = dir.appendingPathComponent("threadmill-relay").path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fallback: search PATH
        return "/usr/local/bin/threadmill-relay"
    }

    func applicationWillTerminate(_ notification: Notification) {
        relayBridge?.stop()
        connectionManager.stop()
        if let surface { ghostty_surface_free(surface) }
        if let ghosttyApp { ghostty_app_free(ghosttyApp) }
        if let ghosttyConfig { ghostty_config_free(ghosttyConfig) }
        unlink(socketPath)
    }
}

// MARK: - RelayBridge
// Bridges the Unix domain socket (from threadmill-relay) to the WebSocket (to Spindle).

@MainActor
class RelayBridge {
    let socketPath: String
    let connectionManager: ConnectionManager
    var onReady: (() -> Void)?

    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    var channelID: UInt16 = 0
    private var isAttached = false
    private var readSource: DispatchSourceRead?
    private var listenSource: DispatchSourceRead?
    private let maxPendingFrames = 500
    private var pendingFrames: [Data] = []

    init(socketPath: String, connectionManager: ConnectionManager) {
        self.socketPath = socketPath
        self.connectionManager = connectionManager
        startListening()
    }

    func start(channelID: UInt16) {
        self.channelID = channelID
        isAttached = channelID > 0

        // Register handler for binary frames from Spindle → relay socket
        connectionManager.setBinaryFrameHandler { [weak self] data in
            self?.handleBinaryFrame(data)
        }
    }

    func setAttachedChannelID(_ channelID: UInt16) {
        guard channelID > 0 else { return }
        self.channelID = channelID
        isAttached = true
    }

    func stop() {
        if let source = readSource {
            readSource = nil
            source.cancel()
        } else if clientFD >= 0 {
            close(clientFD)
            clientFD = -1
        }

        if let source = listenSource {
            listenSource = nil
            source.cancel()
        } else if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    private func startListening() {
        unlink(socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            NSLog("threadmill: socket() failed: %s", String(cString: strerror(errno)))
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { buf in
                _ = socketPath.withCString { strncpy(buf, $0, 103) }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("threadmill: bind(%@) failed: %s", socketPath, String(cString: strerror(errno)))
            Darwin.close(listenFD); listenFD = -1
            return
        }

        guard listen(listenFD, 1) == 0 else {
            NSLog("threadmill: listen() failed: %s", String(cString: strerror(errno)))
            Darwin.close(listenFD); listenFD = -1
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.listenFD, fd >= 0 { Darwin.close(fd) }
            self?.listenFD = -1
        }
        source.resume()
        listenSource = source

        NSLog("threadmill: listening on %@", socketPath)
    }

    private func acceptClient() {
        if let source = readSource {
            readSource = nil
            source.cancel()
        } else if clientFD >= 0 {
            Darwin.close(clientFD)
            clientFD = -1
        }

        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }

        clientFD = fd

        NSLog("threadmill: relay connected")

        // Set up read dispatch source for relay → WebSocket
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readFromRelay()
        }
        let capturedFD = fd
        source.setCancelHandler { [weak self] in
            Darwin.close(capturedFD)
            if self?.clientFD == capturedFD {
                self?.clientFD = -1
            }
        }
        source.resume()
        readSource = source

        flushPendingFrames()
        onReady?()
    }

    // Relay → WebSocket (user keystrokes)
    private func readFromRelay() {
        guard clientFD >= 0 else { return }

        var buf = [UInt8](repeating: 0, count: 16384)
        let n = read(clientFD, &buf, buf.count)
        guard n > 0 else {
            NSLog("threadmill: relay disconnected")
            readSource?.cancel()
            return
        }

        guard connectionManager.state.isConnected else { return }
        guard isAttached, channelID != 0 else { return }

        // Frame: 2-byte channel ID (big-endian) + payload
        var frame = Data(count: 2 + n)
        frame[0] = UInt8(channelID >> 8)
        frame[1] = UInt8(channelID & 0xFF)
        frame.replaceSubrange(2..<(2 + n), with: buf[0..<n])

        Task {
            try? await connectionManager.sendBinaryFrame(frame)
        }
    }

    // WebSocket → relay (remote terminal output)
    private func handleBinaryFrame(_ frame: Data) {
        guard frame.count >= 2 else { return }

        let channel = (UInt16(frame[0]) << 8) | UInt16(frame[1])
        guard channel == channelID || channelID == 0 else { return }

        if channelID == 0 {
            channelID = channel
        }

        // Buffer frames until the relay process connects
        guard clientFD >= 0 else {
            if pendingFrames.count >= maxPendingFrames {
                pendingFrames.removeFirst()
                NSLog("threadmill: pending frame buffer full (%d), dropping oldest frame", maxPendingFrames)
            }
            pendingFrames.append(frame)
            return
        }

        writeFrameToRelay(frame)
    }

    private func flushPendingFrames() {
        guard clientFD >= 0, !pendingFrames.isEmpty else { return }
        let frames = pendingFrames
        pendingFrames.removeAll()
        for frame in frames {
            writeFrameToRelay(frame)
        }
    }

    private func writeFrameToRelay(_ frame: Data) {
        let payload = frame.dropFirst(2)
        guard !payload.isEmpty else { return }

        payload.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress else { return }
            var remaining = payload.count
            var offset = 0
            while remaining > 0 {
                let w = write(clientFD, ptr.advanced(by: offset), remaining)
                if w <= 0 { break }
                offset += w
                remaining -= w
            }
        }
    }
}

// MARK: - GhosttyNSView

class GhosttyNSView: NSView {
    var surface: ghostty_surface_t?
    weak var appDelegate: AppDelegate?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        return layer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let layer = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        layer.contentsScale = scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(
            surface,
            UInt32(bounds.width * scale),
            UInt32(bounds.height * scale)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        ghostty_surface_set_size(surface, UInt32(newSize.width * scale), UInt32(newSize.height * scale))
        // Debounced resize sync to remote tmux pane
        Task { [weak appDelegate] in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms debounce
            await appDelegate?.syncTerminalSize()
        }
    }

    // Accumulated text from interpretKeyEvents/insertText
    private var keyTextAccumulator: [String]?

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Ctrl fast-path: bypass AppKit text interpretation for terminal control input (e.g. Ctrl+D)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) {
            var key_ev = ghostty_input_key_s()
            key_ev.action = action
            key_ev.keycode = UInt32(event.keyCode)
            key_ev.mods = modsFromFlags(event.modifierFlags)
            key_ev.consumed_mods = GHOSTTY_MODS_NONE
            key_ev.composing = false
            key_ev.unshifted_codepoint = unshiftedCodepoint(from: event)

            let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
            if text.isEmpty {
                key_ev.text = nil
                _ = ghostty_surface_key(surface, key_ev)
            } else {
                text.withCString { ptr in
                    key_ev.text = ptr
                    _ = ghostty_surface_key(surface, key_ev)
                }
            }
            return
        }

        // Use AppKit text input system to get composed text
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        interpretKeyEvents([event])

        var key_ev = ghostty_input_key_s()
        key_ev.action = action
        key_ev.keycode = UInt32(event.keyCode)
        key_ev.mods = modsFromFlags(event.modifierFlags)
        key_ev.consumed_mods = consumedMods(from: event.modifierFlags)
        key_ev.unshifted_codepoint = unshiftedCodepoint(from: event)
        key_ev.composing = false

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                if shouldSendText(text) {
                    text.withCString { ptr in
                        key_ev.text = ptr
                        _ = ghostty_surface_key(surface, key_ev)
                    }
                } else {
                    key_ev.text = nil
                    _ = ghostty_surface_key(surface, key_ev)
                }
            }
        } else {
            let text = textForKeyEvent(event)
            if let text, shouldSendText(text) {
                text.withCString { ptr in
                    key_ev.text = ptr
                    _ = ghostty_surface_key(surface, key_ev)
                }
            } else {
                key_ev.text = nil
                _ = ghostty_surface_key(surface, key_ev)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        var key_ev = ghostty_input_key_s()
        key_ev.action = GHOSTTY_ACTION_RELEASE
        key_ev.keycode = UInt32(event.keyCode)
        key_ev.mods = modsFromFlags(event.modifierFlags)
        key_ev.consumed_mods = GHOSTTY_MODS_NONE
        key_ev.text = nil
        key_ev.composing = false
        _ = ghostty_surface_key(surface, key_ev)
    }

    override func flagsChanged(with event: NSEvent) {}

    // insertText from interpretKeyEvents (text composition)
    override func insertText(_ string: Any) {
        let str: String
        if let s = string as? String {
            str = s
        } else if let s = string as? NSAttributedString {
            str = s.string
        } else {
            return
        }
        keyTextAccumulator?.append(str)
    }

    override func doCommand(by selector: Selector) {
        // Key combinations like Enter come through as commands — ignored here,
        // the key event itself handles them.
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, modsFromFlags(event.modifierFlags))
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromFlags(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromFlags(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, modsFromFlags(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, modsFromFlags(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    // MARK: - Key input helpers (modeled on cmux/ghostty)

    private func modsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private func consumedMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        // Ctrl and Cmd never contribute to text translation
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp,
              let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    private func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            // Control characters: return unmodified char so ghostty handles ctrl encoding
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            // PUA function keys: don't send
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return chars
    }

    private func shouldSendText(_ text: String) -> Bool {
        guard let first = text.utf8.first else { return false }
        return first >= 0x20
    }
}

extension NSScreen {
    var displayID: UInt32? {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return id.uint32Value
    }
}
