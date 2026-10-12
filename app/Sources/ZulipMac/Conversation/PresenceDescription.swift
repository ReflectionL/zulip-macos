import Foundation
import ZulipCoreBindings

/// Words for a person's online state and how long ago they were last active.
enum PresenceDescription {
    /// Within this many seconds of activity someone reads as "just now".
    private static let recentSeconds: TimeInterval = 120

    static func text(
        state: PresenceState,
        lastActive: Date?,
        now: Date = .now,
        locale: Locale = .current
    ) -> String {
        switch state {
        case .active:
            return "Active now"
        case .idle:
            return "Idle"
        case .offline:
            guard let lastActive else {
                return "Offline"
            }
            if now.timeIntervalSince(lastActive) < recentSeconds {
                return "Active just now"
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.unitsStyle = .full
            formatter.dateTimeStyle = .named
            return "Active \(formatter.localizedString(for: lastActive, relativeTo: now))"
        }
    }
}
