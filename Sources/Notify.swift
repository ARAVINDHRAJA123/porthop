import Foundation
import UserNotifications

/// System notifications for hops that run by themselves. Permission is asked for only when such a hop is set up.
enum Notify {
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        // Show the banner even while PortHop is the frontmost app.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) { done([.banner, .sound]) }
    }
    private static let presenter = Presenter()
    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }   // only inside the app bundle
        let c = UNUserNotificationCenter.current()
        if c.delegate == nil { c.delegate = presenter }
        return c
    }

    static func requestPermission() { center?.requestAuthorization(options: [.alert, .sound]) { _, _ in } }

    static func post(_ title: String, _ body: String) {
        guard let c = center else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
