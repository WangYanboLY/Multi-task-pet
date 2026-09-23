import AppKit
import Foundation
import os
import UserNotifications

private let helperLogger = Logger(subsystem: "local.agentpet.notifications", category: "delivery")

private struct NotificationPayload {
    let taskID: String
    let source: String
    let title: String

    init?(url: URL, expectedScheme: String) {
        guard url.scheme?.lowercased() == expectedScheme,
              url.host == "notify", url.path.isEmpty, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 3,
              let taskID = items.first(where: { $0.name == "taskID" })?.value,
              let source = items.first(where: { $0.name == "source" })?.value,
              let title = items.first(where: { $0.name == "title" })?.value,
              Set(items.map(\.name)).count == 3,
              !taskID.isEmpty, taskID.utf8.count <= 512,
              !source.isEmpty, source.count <= 48,
              title.count <= 500 else { return nil }
        self.taskID = taskID
        self.source = source
        self.title = title
    }
}

@MainActor
private final class SourceNotificationApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private enum Authorization {
        case notRequested
        case requesting
        case granted
        case denied
    }

    private let center = UNUserNotificationCenter.current()
    private var authorization: Authorization = .notRequested
    private var pending: [NotificationPayload] = []
    private var exitTimer: Timer?

    override init() {
        super.init()
        // Notification Center may launch a stopped helper solely to deliver a
        // tap response. Its delegate must exist before application startup ends.
        center.delegate = self
    }

    private var scheme: String? {
        switch Bundle.main.bundleIdentifier {
        case "local.agentpet.notifications.gpt": return "agentpet-gpt"
        case "local.agentpet.notifications.claude": return "agentpet-claude"
        default: return nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard scheme != nil else {
            helperLogger.error("Unknown notification helper bundle identifier")
            NSApp.terminate(nil)
            return
        }
        armExit(after: 60)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let scheme else { return }
        for url in urls {
            guard let payload = NotificationPayload(url: url, expectedScheme: scheme) else {
                helperLogger.error("Rejected invalid notification URL")
                continue
            }
            exitTimer?.invalidate()
            notify(payload)
        }
    }

    private func notify(_ payload: NotificationPayload) {
        switch authorization {
        case .granted:
            schedule(payload)
        case .denied:
            armExit(after: 3)
            return
        case .requesting:
            pending.append(payload)
        case .notRequested:
            pending.append(payload)
            authorization = .requesting
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                if let error {
                    helperLogger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.authorization = granted ? .granted : .denied
                    let events = self.pending
                    self.pending.removeAll()
                    guard granted else {
                        helperLogger.notice("Source notifications are not authorized")
                        self.armExit(after: 3)
                        return
                    }
                    events.forEach { self.schedule($0) }
                }
            }
        }
    }

    private func schedule(_ payload: NotificationPayload) {
        let content = UNMutableNotificationContent()
        content.title = "\(payload.source) 有新回答"
        content.body = payload.title.isEmpty ? "任务已完成，点击查看。" : payload.title
        content.sound = .default
        content.userInfo = ["taskID": payload.taskID]
        let request = UNNotificationRequest(
            identifier: "agent-pet.source.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                helperLogger.error("Could not schedule source notification: \(error.localizedDescription, privacy: .public)")
                let notificationError = error as NSError
                if notificationError.domain != UNErrorDomain ||
                    notificationError.code != UNError.Code.notificationsNotAllowed.rawValue {
                    Task { @MainActor [weak self] in self?.reportDeliveryFailure(payload) }
                }
            }
            Task { @MainActor [weak self] in self?.armExit(after: 5) }
        }
    }

    private func reportDeliveryFailure(_ payload: NotificationPayload) {
        var components = URLComponents()
        components.scheme = "agentpet"
        components.host = "notification-failed"
        components.queryItems = [
            URLQueryItem(name: "taskID", value: payload.taskID),
            URLQueryItem(name: "source", value: payload.source),
            URLQueryItem(name: "title", value: payload.title)
        ]
        if let url = components.url, !NSWorkspace.shared.open(url) {
            helperLogger.error("Could not request fallback notification from Agent Pet")
        }
    }

    private func armExit(after seconds: TimeInterval) {
        exitTimer?.invalidate()
        exitTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in NSApp.terminate(nil) }
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
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let taskID = response.notification.request.content.userInfo["taskID"] as? String,
              !taskID.isEmpty, taskID.utf8.count <= 512 else {
            completionHandler()
            return
        }
        completionHandler()
        Task { @MainActor in
            self.exitTimer?.invalidate()
            var components = URLComponents()
            components.scheme = "agentpet"
            components.host = "task"
            components.queryItems = [URLQueryItem(name: "taskID", value: taskID)]
            if let url = components.url, !NSWorkspace.shared.open(url) {
                helperLogger.error("Could not open Agent Pet task route")
            }
            self.armExit(after: 2)
        }
    }
}

@main
@MainActor
private enum SourceNotificationMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = SourceNotificationApp()
        application.delegate = delegate
        application.run()
    }
}
