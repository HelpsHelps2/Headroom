import AppKit
import UserNotifications

/// Posts the low-space notification. Only a bundled app may use the notification center: calling it from `swift run` crashes.
final class LowSpaceNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = LowSpaceNotifier()
    private var usable: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    func start() {
        if usable { UNUserNotificationCenter.current().delegate = self }
    }

    /// Returns false when notifications are turned off for Headroom. Asks the first time one is needed.
    func post(title: String, body: String) async -> Bool {
        guard usable else { return true }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // A fixed identifier replaces the previous alert instead of stacking them.
        try? await center.add(UNNotificationRequest(identifier: "low-space", content: content, trigger: nil))
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { AppModel.shared.windowRequests += 1 }
    }
}
