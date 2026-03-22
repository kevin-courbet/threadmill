import ACPModel
import XCTest
@testable import Threadmill

@MainActor
final class ChatSessionViewModelTests: XCTestCase {
    func testSelectAgentUpdatesSelectionWhenNotStreaming() async {
        let viewModel = ChatSessionViewModel(
            agentSessionManager: nil,
            selectedAgentName: "opencode",
            availableAgents: [
                AgentConfig(name: "opencode", command: "opencode", cwd: nil),
                AgentConfig(name: "claude", command: "claude", cwd: nil),
            ]
        )

        await viewModel.selectAgent(named: "claude")

        XCTAssertEqual(viewModel.selectedAgentName, "claude")
    }

    func testSelectAgentDoesNotChangeWhileStreaming() async {
        let viewModel = ChatSessionViewModel(agentSessionManager: nil, selectedAgentName: "opencode")
        viewModel.isStreaming = true

        await viewModel.selectAgent(named: "claude")

        XCTAssertEqual(viewModel.selectedAgentName, "opencode")
    }

    func testCycleModeForwardLoopsThroughModes() async {
        let modes = [
            ModeInfo(id: "chat", name: "Chat"),
            ModeInfo(id: "code", name: "Code"),
            ModeInfo(id: "plan", name: "Plan"),
        ]
        let viewModel = ChatSessionViewModel(agentSessionManager: nil, availableModes: modes)

        await viewModel.cycleModeForward()
        XCTAssertEqual(viewModel.currentMode, "code")

        await viewModel.cycleModeForward()
        XCTAssertEqual(viewModel.currentMode, "plan")

        await viewModel.cycleModeForward()
        XCTAssertEqual(viewModel.currentMode, "chat")
    }
}
