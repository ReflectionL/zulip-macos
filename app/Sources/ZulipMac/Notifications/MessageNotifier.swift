import AppKit
import Foundation
import Observation
import OSLog
import UserNotifications

private let notificationLog = Logger(
    subsystem: "io.github.huahai.ZulipMac",
    category: "notifications"
)

/// Delivers local notifications and the Dock badge. Kept behind a protocol so
/// tests and unbundled builds never touch the system notification center.
@MainActor
protocol MessageNotifier: AnyObject {
    var onActivate: ((NotificationRoute) -> Void)? { get set }
    var onApplicationActivated: (() -> Void)? { get set }
    /// Called when the user has switched notifications off for the app in System Settings.
    var onNotificationsDisabled: (() -> Void)? { get set }

    func requestAuthorization()
    func post(_ notification: MessageNotification)
    func setBadge(_ count: Int)
}

/// What macOS currently allows the app to show.
enum NotificationPermission: Equatable, Sendable {
    /// Not read from the system yet.
    case unknown
    /// The app has not asked yet (or macOS forgot an earlier answer).
    case notRequested
    case allowed
    /// Allowed, but the alert style is None, so nothing appears on screen.
    case alertsOff
    case denied

    var label: String {
        switch self {
        case .unknown: "Checking…"
        case .notRequested: "Not requested yet"
        case .allowed: "Allowed"
        case .alertsOff: "Allowed, but alerts are set to None"
        case .denied: "Turned off in System Settings"
        }
    }
}

/// The notification permission as last read from macOS, for the Settings window.
@MainActor
@Observable
final class NotificationStatus {
    var permission = NotificationPermission.unknown
    /// Why the last request for permission or test notification failed.
    var lastError: String?
}

@MainActor
final class SystemMessageNotifier: NSObject, MessageNotifier, UNUserNotificationCenterDelegate {
    private static let routeKey = "route"

    let status = NotificationStatus()

    var onActivate: ((NotificationRoute) -> Void)?
    var onApplicationActivated: (() -> Void)?
    var onNotificationsDisabled: (() -> Void)?

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
        // Ask at launch, not only once signed in: a fresh install or an update
        // that macOS treats as a new app gets the permission prompt right away.
        // Deferred so the app has finished launching and the session has set
        // its callbacks first.
        Task { @MainActor [weak self] in
            self?.requestAuthorization()
        }
    }

    /// Reads the current permission and, when the app has not asked yet, asks.
    func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let permission = Self.permission(from: settings)
            notificationLog.info(
                "notification authorization status \(settings.authorizationStatus.rawValue, privacy: .public)"
            )
            self?.publish(permission)
            switch permission {
            case .notRequested:
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                        notificationLog.info(
                            "notification authorization granted \(granted, privacy: .public)"
                        )
                        if let error {
                            notificationLog.error(
                                "notification authorization failed: \(error.localizedDescription, privacy: .public)"
                            )
                            self?.publish(error: error.localizedDescription)
                        }
                        if !granted {
                            self?.reportDisabled()
                        }
                        self?.readPermission()
                    }
            case .denied, .alertsOff:
                self?.reportDisabled()
            case .allowed, .unknown:
                break
            }
        }
    }

    /// Re-reads the permission, for example after the user changed it in System Settings.
    func refreshPermission() {
        guard isAvailable else { return }
        readPermission()
    }

    private nonisolated func readPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            self?.publish(Self.permission(from: settings))
        }
    }

    /// Posts a sample notification so the user can see what one looks like.
    func sendTestNotification() {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Zulip Mac"
        content.body = "Notifications are working."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "test-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        status.lastError = nil
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.publish(error: error.localizedDescription)
            }
        }
    }

    /// Opens this app's page in System Settings › Notifications.
    func openSystemSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.huahai.ZulipMac"
        let specific = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)"
        )
        let general = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        guard let url = specific ?? general else { return }
        NSWorkspace.shared.open(url)
    }

    private nonisolated static func permission(
        from settings: UNNotificationSettings
    ) -> NotificationPermission {
        switch settings.authorizationStatus {
        case .notDetermined:
            .notRequested
        case .denied:
            .denied
        default:
            settings.alertSetting == .disabled || settings.alertStyle == .none
                ? .alertsOff
                : .allowed
        }
    }

    private nonisolated func publish(_ permission: NotificationPermission) {
        Task { @MainActor [weak self] in
            self?.status.permission = permission
            if permission == .allowed {
                self?.status.lastError = nil
            }
        }
    }

    private nonisolated func publish(error: String) {
        Task { @MainActor [weak self] in
            self?.status.lastError = error
        }
    }

    private nonisolated func reportDisabled() {
        Task { @MainActor [weak self] in
            self?.onNotificationsDisabled?()
        }
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
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                notificationLog.error(
                    "could not post notification: \(error.localizedDescription, privacy: .public)"
                )
                self?.signalUndeliveredNotification()
            }
        }
    }

    /// When the system refuses a notification, a Dock bounce and the alert sound
    /// still tell the user something arrived instead of failing silently.
    private nonisolated func signalUndeliveredNotification() {
        Task { @MainActor in
            guard !NSApplication.shared.isActive else { return }
            NSApplication.shared.requestUserAttention(.informationalRequest)
            NSSound.beep()
        }
    }

    func setBadge(_ count: Int) {
        guard isAvailable else { return }
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    private func applicationActivated() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        refreshPermission()
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
