import AppKit
import Foundation
import UserNotifications

/// Delivers local notifications and the Dock badge. Kept behind a protocol so
/// tests and unbundled builds never touch the system notification center.
@MainActor
protocol MessageNotifier: AnyObject {
    var onActivate: ((NotificationRoute) -> Void)? { get set }
    var onApplicationActivated: (() -> Void)? { get set }

    func requestAuthorization()
    func post(_ notification: MessageNotification)
    func setBadge(_ count: Int)
}

@MainActor
final class SystemMessageNotifier: NSObject, MessageNotifier, UNUserNotificationCenterDelegate {
    private static let routeKey = "route"

    var onActivate: ((NotificationRoute) -> Void)?
    var onApplicationActivated: (() -> Void)?

    /// `UNUserNotificationCenter` traps outside an app bundle (for example in
    /// `swift test`), so everything is a no-op unless running as a `.app`.
    private let isAvailable = Bundle.main.bundleURL.pathExtension == "app"
    private var activationObserver: NSObjectProtocol?

    override init() {
        super.init()
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applicationActivated()
            }
        }
    }

    func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ notification: MessageNotification) {
        guard isAvailable, let route = notification.route.encoded else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = route
        content.userInfo = [Self.routeKey: route]
        let request = UNNotificationRequest(
            identifier: "message-\(notification.route.messageID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func setBadge(_ count: Int) {
        guard isAvailable else { return }
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    private func applicationActivated() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        setBadge(0)
        onApplicationActivated?()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let encoded = response.notification.request.content.userInfo["route"] as? String,
              let route = NotificationRoute(encoded: encoded)
        else {
            return
        }
        await MainActor.run {
            NSApplication.shared.activate()
            onActivate?(route)
        }
    }
}
