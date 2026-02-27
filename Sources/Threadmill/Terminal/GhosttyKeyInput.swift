enum GhosttyKeyInput {
    static func shouldSendText(_ text: String) -> Bool {
        guard let first = text.utf8.first else { return false }
        return first >= 0x20 && first != 0x7F
    }
}
