import AppKit
import UserNotifications

/// Posts the low-space notification. Only a bundled app may use the notification center: calling it from `swift run` crashes.
final class LowSpaceNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = LowSpaceNotifier()
    private var usable: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    func start() {
        if usable { UNUserNotificationCenter.current().delegate = self }
    }

    /// Returns whether the notification was handed to macOS. Asks for permission the first time one is needed.
    func post(title: String, body: String) async -> Bool {
        guard usable else { return false }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // A fixed identifier replaces the previous alert instead of stacking them.
        do {
            try await center.add(UNNotificationRequest(identifier: "low-space", content: content, trigger: nil))
            return true
        } catch { return false }
    }

    var denied: Bool {
        get async {
            guard usable else { return false }
            return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
        }
    }

    // The completion-handler forms on purpose: the async forms finish away from the main thread, which AppKit can reject.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in AppModel.shared.windowRequests += 1 }
        completionHandler()
    }
}
