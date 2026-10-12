import AppKit
import SkylineCore
import UserNotifications

/// Posts what `NotificationPlanner` decides (T8, L19) and routes a click back into the app. The
/// notification center is only touched once the user turns a notification on, so a fresh install never
/// sees a permission prompt it didn't ask for, and test runs (stress, measurement) post nothing.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called when the user clicks a notification: (location id, alert id).
    var onOpen: ((String, String?) -> Void)?
    private(set) var authorized: Bool?
    private var center: UNUserNotificationCenter?

    /// Bundle-less runs (swift run) can't use the notification center at all.
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    private func activeCenter() -> UNUserNotificationCenter? {
        guard Self.available else { return nil }
        if let center { return center }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        center = c
        return c
    }

    /// Asks macOS for permission (shows the system prompt the first time). Returns whether it's allowed.
    func requestAuthorization() async -> Bool {
        guard let c = activeCenter() else { return false }
        let granted = (try? await c.requestAuthorization(options: [.alert, .sound])) ?? false
        authorized = granted
        return granted
    }

    /// Current permission without prompting (nil = never asked).
    func refreshAuthorization() async -> UNAuthorizationStatus? {
        guard let c = activeCenter() else { return nil }
        let status = await c.notificationSettings().authorizationStatus
        authorized = status == .authorized || status == .provisional
        return status
    }

    func post(_ items: [PlannedNotification]) {
        guard !items.isEmpty, let c = activeCenter() else { return }
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.interruptionLevel = item.timeSensitive ? .timeSensitive : .active
            content.threadIdentifier = item.locationID
            var info: [String: String] = ["location": item.locationID]
            if let a = item.alertID { info["alert"] = a }
            content.userInfo = info
            c.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
        }
    }

    // Show banners even while Skyline is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .sound, .list] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let location = info["location"] as? String
        let alert = info["alert"] as? String
        await MainActor.run {
            if let location { self.onOpen?(location, alert) }
        }
    }
}
