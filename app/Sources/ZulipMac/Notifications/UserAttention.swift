import AppKit
import Foundation

/// Whether anyone can be looking at the screen. A locked Mac, a sleeping display
/// or an inactive login session leave the frontmost app "active", so the app's
/// own active state alone would treat a message that arrives meanwhile as read
/// and skip both its notification and its Dock badge.
@MainActor
final class UserAttention {
    var isScreenLocked = false {
        didSet { stateChanged(from: oldValue, isScreenLocked) }
    }

    var areScreensAsleep = false {
        didSet { stateChanged(from: oldValue, areScreensAsleep) }
    }

    var isSessionInactive = false {
        didSet { stateChanged(from: oldValue, isSessionInactive) }
    }

    /// Called when the user comes back: unlock, display wake or session switch.
    var onReturn: (() -> Void)?

    var isAway: Bool {
        isScreenLocked || areScreensAsleep || isSessionInactive
    }

    init(observing: Bool = true) {
        guard observing else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.screensDidSleepNotification, on: workspace) { $0.areScreensAsleep = true }
        observe(NSWorkspace.screensDidWakeNotification, on: workspace) { $0.areScreensAsleep = false }
        observe(NSWorkspace.sessionDidResignActiveNotification, on: workspace) {
            $0.isSessionInactive = true
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, on: workspace) {
            $0.isSessionInactive = false
        }
        // Posted by loginwindow when the screen locks or unlocks; not public API
        // constants, but stable for many macOS releases.
        let distributed = DistributedNotificationCenter.default()
        observe(Notification.Name("com.apple.screenIsLocked"), on: distributed) {
            $0.isScreenLocked = true
        }
        observe(Notification.Name("com.apple.screenIsUnlocked"), on: distributed) {
            $0.isScreenLocked = false
        }
    }

    private func observe(
        _ name: Notification.Name,
        on center: NotificationCenter,
        _ update: @escaping @MainActor (UserAttention) -> Void
    ) {
        // Lives as long as the app, like the session that owns it, so the tokens
        // are never removed.
        _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self {
                    update(self)
                }
            }
        }
    }

    private func stateChanged(from old: Bool, _ new: Bool) {
        guard old != new, !new, !isAway else { return }
        onReturn?()
    }
}
