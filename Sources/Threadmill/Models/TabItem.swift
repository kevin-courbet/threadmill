import SwiftUI

struct TabItem: Identifiable, Hashable, Codable {
    let id: String
    let localizedKey: String
    let icon: String

    var title: LocalizedStringKey {
        LocalizedStringKey(localizedKey)
    }

    static let chat = TabItem(id: "chat", localizedKey: "Chat", icon: "message")
    static let terminal = TabItem(id: "terminal", localizedKey: "Terminal", icon: "terminal")
    static let files = TabItem(id: "files", localizedKey: "Files", icon: "folder")
    static let browser = TabItem(id: "browser", localizedKey: "Browser", icon: "globe")

    static let modeDefaults: [TabItem] = [.chat, .terminal, .files, .browser]
}
