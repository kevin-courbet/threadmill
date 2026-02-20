import AppKit
import Foundation
import SwiftTerm
import SwiftUI

@MainActor
final class TerminalBridge: NSObject, ObservableObject {
    private let connectionManager: ConnectionManager
    private weak var terminalView: TerminalView?

    private var channelID: UInt16?
    private var attachTask: Task<Void, Never>?

    init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager
        super.init()

        connectionManager.setBinaryFrameHandler { [weak self] data in
            Task { @MainActor [weak self] in
                self?.handleBinaryFrame(data)
            }
        }
    }

    func bindTerminalView(_ terminalView: TerminalView) {
        self.terminalView = terminalView
        terminalView.terminalDelegate = self
        terminalView.nativeBackgroundColor = .textBackgroundColor
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        attachIfNeeded()
    }

    func attachIfNeeded() {
        guard connectionManager.state.isConnected,
              channelID == nil,
              attachTask == nil
        else {
            return
        }

        attachTask = Task { @MainActor [weak self] in
            defer { self?.attachTask = nil }
            await self?.attachRemoteTerminal()
        }
    }

    func resetAttachment() {
        channelID = nil
    }

    private func attachRemoteTerminal() async {
        do {
            let result = try await connectionManager.request(
                method: "terminal.attach",
                params: ["session": ThreadmillConfig.testSession],
                timeout: 10
            )

            channelID = parseChannelID(from: result)
        } catch {
            channelID = nil
        }
    }

    private func parseChannelID(from result: Any) -> UInt16? {
        if let intValue = result as? Int {
            return UInt16(clamping: intValue)
        }

        if let dictionary = result as? [String: Any] {
            if let intValue = dictionary["channel_id"] as? Int {
                return UInt16(clamping: intValue)
            }
            if let stringValue = dictionary["channel_id"] as? String,
               let parsed = UInt16(stringValue)
            {
                return parsed
            }
        }

        return nil
    }

    private func handleBinaryFrame(_ frame: Data) {
        guard frame.count >= 2,
              let expectedChannel = channelID
        else {
            return
        }

        let channel = (UInt16(frame[0]) << 8) | UInt16(frame[1])
        guard channel == expectedChannel else {
            return
        }

        let payload = frame.dropFirst(2)
        let bytes = [UInt8](payload)
        terminalView?.feed(byteArray: bytes[...])
    }

    private func sendResize(cols: Int, rows: Int) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.channelID != nil,
                  self.connectionManager.state.isConnected
            else {
                return
            }

            _ = try? await self.connectionManager.request(
                method: "terminal.resize",
                params: [
                    "session": ThreadmillConfig.testSession,
                    "cols": cols,
                    "rows": rows
                ],
                timeout: 10
            )
        }
    }
}

extension TerminalBridge: TerminalViewDelegate {
    nonisolated func send(source _: TerminalView, data: ArraySlice<UInt8>) {
        let payload = [UInt8](data)

        Task { @MainActor [weak self] in
            guard let self,
                  let channelID = self.channelID,
                  self.connectionManager.state.isConnected
            else {
                return
            }

            var frame = Data([UInt8(channelID >> 8), UInt8(channelID & 0xFF)])
            frame.append(contentsOf: payload)
            try? await self.connectionManager.sendBinaryFrame(frame)
        }
    }

    nonisolated func sizeChanged(source _: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor [weak self] in
            self?.sendResize(cols: newCols, rows: newRows)
        }
    }

    nonisolated func setTerminalTitle(source _: TerminalView, title _: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {}

    nonisolated func scrolled(source _: TerminalView, position _: Double) {}

    nonisolated func clipboardCopy(source _: TerminalView, content _: Data) {}

    nonisolated func rangeChanged(source _: TerminalView, startY _: Int, endY _: Int) {}
}

struct ThreadmillTerminalView: NSViewRepresentable {
    @ObservedObject var bridge: TerminalBridge

    func makeNSView(context _: Context) -> TerminalView {
        let terminalView = TerminalView(frame: .zero)
        bridge.bindTerminalView(terminalView)
        return terminalView
    }

    func updateNSView(_: TerminalView, context _: Context) {
        bridge.attachIfNeeded()
    }
}
