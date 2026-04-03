import Foundation
import UserNotifications
import os

@MainActor
final class NotificationService: NotificationServicing {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Logger.state.error("Notification permission request failed: \(error)")
                return
            }
            Logger.state.info("Notification permission granted=\(granted)")
        }
    }

    func notifyAgentFinished(threadName: String, projectName _: String?) {
        let content = UNMutableNotificationContent()
        content.title = threadName
        content.body = "Agent finished"
        content.threadIdentifier = threadName
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                Logger.state.error("Failed to post completion notification: \(error)")
            }
        }
    }
}
