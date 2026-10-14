import Foundation
import ZulipCoreBindings

/// The account's Zulip notification choices for channels and topics, taken
/// from a live snapshot: the account-wide default, each channel's own choice,
/// muted channels and the muted, unmuted and followed topics.
struct ChannelNotificationSettings: Equatable, Sendable {
    private struct TopicKey: Hashable {
        let streamID: Int64
        /// Zulip compares topic names without regard to case.
        let topic: String

        init(streamID: Int64, topic: String) {
            self.streamID = streamID
            self.topic = topic.lowercased()
        }
    }

    private let mutedChannels: Set<Int64>
    private let channelChoices: [Int64: Bool]
    private let notifiesByDefault: Bool
    private let topicVisibility: [TopicKey: LiveTopicVisibility]

    init(snapshot: LiveSnapshot) {
        mutedChannels = Set(snapshot.channels.filter(\.isMuted).map(\.streamID))
        channelChoices = Dictionary(
            snapshot.channels.compactMap { channel in
                channel.desktopNotifications.map { (channel.streamID, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        notifiesByDefault = snapshot.channelNotificationsDefault
        topicVisibility = Dictionary(
            snapshot.topicPolicies.map {
                (TopicKey(streamID: $0.streamID, topic: $0.topic), $0.visibility)
            },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    /// Whether a topic is hidden from notifications and unread counts: it is
    /// muted itself, or it sits in a muted channel without being unmuted.
    func isMuted(streamID: Int64, topic: String?) -> Bool {
        switch visibility(streamID: streamID, topic: topic) {
        case .muted:
            true
        case .unmuted, .followed:
            false
        case nil:
            mutedChannels.contains(streamID)
        }
    }

    /// Whether a new channel message should raise a notification: followed
    /// topics always do, muted ones never, and otherwise a mention does, or
    /// every message when the channel (or the account default) asks for it.
    func notifies(streamID: Int64, topic: String?, isMention: Bool) -> Bool {
        if visibility(streamID: streamID, topic: topic) == .followed {
            return true
        }
        if isMuted(streamID: streamID, topic: topic) {
            return false
        }
        return isMention || (channelChoices[streamID] ?? notifiesByDefault)
    }

    private func visibility(streamID: Int64, topic: String?) -> LiveTopicVisibility? {
        topicVisibility[TopicKey(streamID: streamID, topic: topic ?? "")]
    }
}
