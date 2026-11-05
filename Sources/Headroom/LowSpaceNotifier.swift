import AppKit
import UserNotifications

/// Posts the low-space notification. Only a bundled app may use the notification center: calling it from `swift run` crashes.
final class LowSpaceNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = LowSpaceNotifier()
    private var refused = false
    private var usable: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    func start() {
        guard usable else { return }
        UNUserNotificationCenter.current().delegate = self
        // Ask at launch, not at the first alert, when the disk is already full. macOS only shows this once. It finishes
        // when the prompt is answered, which may be never, so nothing else may wait on it.
        Task { @MainActor in
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            } catch {
                // macOS refuses outright, without asking, for a copy outside Applications.
                refused = true
            }
            AppModel.shared.notificationProblem = await problem
        }
    }

    /// Returns whether the notification was handed to macOS.
    func post(title: String, body: String) async -> Bool {
        guard usable else { return false }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // A fixed identifier replaces the previous alert instead of stacking them.
        do {
            try await center.add(UNNotificationRequest(identifier: "low-space", content: content, trigger: nil))
            return true
        } catch { return false }
    }

    /// What's stopping alerts, for Settings.
    var problem: String? {
        get async {
            guard usable else { return nil }
            if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied {
                return "Notifications are off for Headroom in System Settings."
            }
            return refused ? "macOS blocks notifications here. Move Headroom to Applications to get alerts." : nil
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
