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

    /// The topic's own choice, or `.standard` when it follows its channel.
    func level(streamID: Int64, topic: String?) -> TopicNotificationLevel {
        switch visibility(streamID: streamID, topic: topic) {
        case .muted: .muted
        case .unmuted: .unmuted
        case .followed: .followed
        case nil: .standard
        }
    }

    /// Whether a new channel message should raise a notification, as Zulip decides:
    /// a followed topic notifies about everything; an @-mention of the user
    /// notifies even in a muted channel or topic; muted channels and topics are
    /// otherwise silent (an @all/@topic mention included); anything else
    /// notifies when the channel (or the account default) asks for every message.
    func notifies(
        streamID: Int64,
        topic: String?,
        isPersonalMention: Bool,
        isWildcardMention: Bool = false
    ) -> Bool {
        if visibility(streamID: streamID, topic: topic) == .followed || isPersonalMention {
            return true
        }
        if isMuted(streamID: streamID, topic: topic) {
            return false
        }
        return isWildcardMention || (channelChoices[streamID] ?? notifiesByDefault)
    }

    private func visibility(streamID: Int64, topic: String?) -> LiveTopicVisibility? {
        topicVisibility[TopicKey(streamID: streamID, topic: topic ?? "")]
    }
}
