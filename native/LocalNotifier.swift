import Foundation
import os
import UserNotifications

private let notificationLogger = Logger(subsystem: "local.agentpet.desktop", category: "notifications")

@MainActor
final class LocalNotifier: NSObject, UNUserNotificationCenterDelegate {
    private struct PendingNotification {
        let taskID: String
        let source: String
        let title: String
    }

    private enum PermissionState {
        case notRequested
        case requesting
        case granted
        case denied
    }

    private let center = UNUserNotificationCenter.current()
    private var permissionState: PermissionState = .notRequested
    private var pending: [PendingNotification] = []
    private var onOpen: ((String) -> Void)?

    /// Call during app startup, before notifications can be delivered.
    func prepare(onOpen: @escaping (String) -> Void) {
        self.onOpen = onOpen
        center.delegate = self
    }

    /// Requests permission only when there is a new event worth notifying about.
    func notify(taskID: String, source: String, title: String) {
        guard !taskID.isEmpty else { return }
        let event = PendingNotification(taskID: taskID, source: source, title: title)

        switch permissionState {
        case .granted:
            schedule(event)
        case .denied:
            return
        case .requesting:
            pending.append(event)
        case .notRequested:
            pending.append(event)
            permissionState = .requesting
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                if let error {
                    notificationLogger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.permissionState = granted ? .granted : .denied
                    let events = self.pending
                    self.pending.removeAll()
                    guard granted else {
                        notificationLogger.notice("Local notifications are not authorized")
                        return
                    }
                    events.forEach { self.schedule($0) }
                }
            }
        }
    }

    private func schedule(_ event: PendingNotification) {
        let content = UNMutableNotificationContent()
        let source = event.source.trimmingCharacters(in: .whitespacesAndNewlines)
        content.title = "\(source.isEmpty ? "任务" : source) 有新回答"
        content.body = event.title.isEmpty ? "任务已完成，点击查看。" : event.title
        content.sound = .default
        content.userInfo = ["taskID": event.taskID]

        let request = UNNotificationRequest(
            identifier: "agent-pet.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                notificationLogger.error("Could not schedule local notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let taskID = response.notification.request.content.userInfo["taskID"] as? String
        if let taskID {
            Task { @MainActor [weak self] in
                self?.onOpen?(taskID)
                completionHandler()
            }
        } else {
            completionHandler()
        }
    }
}
