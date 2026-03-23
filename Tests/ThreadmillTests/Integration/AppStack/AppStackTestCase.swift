import Foundation
import XCTest
@testable import Threadmill

/// Base class for AppStack integration tests.
///
/// Unlike Protocol tests (which use a raw WebSocket), these tests instantiate
/// the real Swift app objects — AppState, ConnectionManager, AgentSessionManager,
/// DatabaseManager — and point them at real Spindle on beast.
///
/// This is the layer that catches wiring bugs: wrong SQL queries, connection
/// ordering, FK constraints, binary frame routing, event handling — anything
/// that breaks when the real classes interact with the real daemon.
///
/// Subclass this and use `appState`, `connectionManager`, `databaseManager`
/// directly. The base class handles connection lifecycle and cleanup.
@MainActor
class AppStackTestCase: XCTestCase {
    // TODO: Instantiate real AppState, ConnectionManager, DatabaseManager, AgentSessionManager
    // pointed at real Spindle via SSH tunnel (localhost:19990).
    //
    // Key decisions:
    // - WebSocketClient connects to ws://127.0.0.1:19990 (tunnel must be up)
    // - DatabaseManager uses a temp GRDB path (cleaned in tearDown)
    // - AppState.onConnected triggers real sync (project.list, thread.list)
    // - AgentSessionManager handles real binary frames
    //
    // The fixture repo at /home/wsl/dev/threadmill-test-fixture must be added.
    // Thread cleanup uses the same test- prefix sweep as Protocol tests.
}
