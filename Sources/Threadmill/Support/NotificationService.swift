import Foundation
import os
import UserNotifications

@MainActor
final class NotificationService: NotificationServicing {
    private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }

    func requestPermission() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Logger.state.error("Notification permission request failed: \(error)")
                return
            }

            Logger.state.info("Notification permission granted=\(granted)")
        }
    }

    func notifyAgentFinished(threadName: String, projectName: String?) {
        let content = UNMutableNotificationContent()
        content.title = threadName
        content.body = notificationBody(projectName: projectName)
        content.threadIdentifier = threadName

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        notificationCenter.add(request) { error in
            if let error {
                Logger.state.error("Failed to enqueue completion notification: \(error)")
            }
        }
    }

    private func notificationBody(projectName: String?) -> String {
        guard let projectName,
              !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Agent finished"
        }

        return "Agent finished in \(projectName)"
    }
}

@MainActor
final class NoopNotificationService: NotificationServicing {
    func requestPermission() {}

    func notifyAgentFinished(threadName _: String, projectName _: String?) {}
}
