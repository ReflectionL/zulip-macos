import SwiftUI

/// Shows whether macOS lets the app post notifications and offers the fixes:
/// ask again, open System Settings, or send a test notification.
struct NotificationSettingsSection: View {
    let notifier: SystemMessageNotifier

    var body: some View {
        let status = notifier.status
        Section("Notifications") {
            LabeledContent("Permission") {
                Text(status.permission.label)
                    .foregroundStyle(status.permission == .allowed ? Color.secondary : Color.orange)
            }

            if let hint = hint(for: status.permission) {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = status.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if status.permission == .notRequested {
                    Button("Allow Notifications") {
                        notifier.requestAuthorization()
                    }
                }
                Button("Open System Settings") {
                    notifier.openSystemSettings()
                }
            }

            Button("Send Test Notification") {
                notifier.sendTestNotification()
            }
            .disabled(status.permission != .allowed)
        }
        .onAppear { notifier.refreshPermission() }
    }

    private func hint(for permission: NotificationPermission) -> String? {
        switch permission {
        case .notRequested:
            "Zulip Mac asks when it opens. Click Allow on the macOS prompt."
        case .denied:
            "macOS asks only once. Turn on Allow Notifications for Zulip Mac in System Settings."
        case .alertsOff:
            "Set the alert style to Banners or Alerts in System Settings to see notifications."
        case .allowed, .unknown:
            nil
        }
    }
}
