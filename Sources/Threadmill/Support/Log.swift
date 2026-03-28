import os

/// Structured logging via os.Logger.
///
/// Each subsystem category maps to a domain boundary in the app.
/// Use the appropriate logger for the call site — this enables
/// per-category filtering in Console.app and programmatic capture
/// via OSLogStore in tests.
///
/// Log levels:
///   .debug   — verbose, only visible with explicit Console.app filter
///   .info    — lifecycle transitions, state changes
///   .notice  — default, noteworthy but expected events
///   .error   — recoverable failures
///   .fault   — unrecoverable / invariant violations
extension Logger {
    private static let subsystem = "dev.threadmill"

    /// App bootstrap, lifecycle
    static let boot = Logger(subsystem: subsystem, category: "boot")

    /// AppState: selection, events, daemon event handling
    static let state = Logger(subsystem: subsystem, category: "state")

    /// ConnectionManager: connect/disconnect/reconnect/handshake
    static let conn = Logger(subsystem: subsystem, category: "conn")

    /// SSH tunnel lifecycle
    static let tunnel = Logger(subsystem: subsystem, category: "tunnel")

    /// SyncService: daemon → GRDB sync
    static let sync = Logger(subsystem: subsystem, category: "sync")

    /// TerminalMultiplexer: channel dispatch, reattach
    static let mux = Logger(subsystem: subsystem, category: "mux")

    /// RelayEndpoint: PTY shim, binary frames, socket lifecycle
    static let relay = Logger(subsystem: subsystem, category: "relay")

    /// GhosttySurfaceHost: surface create/free, child exit
    static let ghostty = Logger(subsystem: subsystem, category: "ghostty")

    /// AgentSessionManager: ACP sessions, binary deframing
    static let agent = Logger(subsystem: subsystem, category: "agent")

    /// Chat lifecycle: session bootstrap, attach, send
    static let chat = Logger(subsystem: subsystem, category: "chat")

    /// BrowserSessionManager: tab CRUD, navigation
    static let browser = Logger(subsystem: subsystem, category: "browser")

    /// GitHub OAuth device flow
    static let github = Logger(subsystem: subsystem, category: "github")

    /// View-layer tracing (attach flow, mode switching, restore)
    static let view = Logger(subsystem: subsystem, category: "view")
}
