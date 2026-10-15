import Foundation
import Observation
import SwiftUI

/// How much empty space sits between messages in a conversation.
enum MessageDensity: String, CaseIterable, Identifiable, Sendable {
    case normal
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .compact: "Compact"
        }
    }

    /// Vertical padding above and below a message that continues a block.
    var continuationInset: CGFloat {
        switch self {
        case .normal: AppTheme.Metrics.continuationInset
        case .compact: 1
        }
    }

    /// Padding above the first message of a block (the sender's name row).
    var blockTopInset: CGFloat {
        switch self {
        case .normal: AppTheme.Metrics.blockTopInset
        case .compact: 6
        }
    }

    /// Padding below the first message of a block.
    var blockBottomInset: CGFloat {
        switch self {
        case .normal: AppTheme.Metrics.blockBottomInset
        case .compact: 1
        }
    }
}

/// The user's message-density preference, remembered across launches. Rows read
/// `density` while building their body, so a change redraws the timeline.
@MainActor
@Observable
final class MessageDensityPreference {
    static let shared = MessageDensityPreference()

    private static let defaultsKey = "messageDensity"

    private(set) var density: MessageDensity
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        density = defaults.string(forKey: Self.defaultsKey)
            .flatMap(MessageDensity.init(rawValue:)) ?? .normal
    }

    func select(_ value: MessageDensity) {
        guard value != density else {
            return
        }
        density = value
        defaults.set(value.rawValue, forKey: Self.defaultsKey)
    }
}
