import Foundation
import ZulipCoreBindings

/// Unread counts for the sidebar and the Dock badge, derived from the core's
/// per-conversation buckets.
struct UnreadSummary: Equatable {
    struct TopicKey: Hashable {
        let streamID: Int64
        let topic: String
    }

    /// Unread messages per channel. Muted channels and topics are left out, as in Zulip.
    private(set) var channels: [Int64: Int] = [:]
    private(set) var topics: [TopicKey: Int] = [:]
    /// Unread messages per one-to-one conversation, keyed by the other person
    /// (the user's own ID for notes to self).
    private(set) var directMessages: [Int64: Int] = [:]
    /// Unread messages anywhere that mention the user.
    private(set) var mentions = 0
    /// What the Dock badge shows: every unread direct message, group ones too,
    /// plus unread mentions in channels that are not muted.
    private(set) var badge = 0
    /// What the account chose for channels and topics, when the summary knows it.
    private(set) var settings: ChannelNotificationSettings?

    init() {}

    /// The topic's own notification choice.
    func topicLevel(streamID: Int64, topic: String) -> TopicNotificationLevel {
        settings?.level(streamID: streamID, topic: topic) ?? .standard
    }

    /// `settings`, when given, decides what is muted (topics included);
    /// otherwise only `mutedChannels` are.
    init(
        buckets: [LiveUnreadBucket],
        selfUserID: Int64,
        mutedChannels: Set<Int64>,
        settings: ChannelNotificationSettings? = nil
    ) {
        self.settings = settings
        for bucket in buckets where bucket.count > 0 {
            if let streamID = bucket.streamID {
                mentions += bucket.mentionCount
                let isMuted = settings?.isMuted(streamID: streamID, topic: bucket.topic)
                    ?? mutedChannels.contains(streamID)
                if isMuted {
                    continue
                }
                channels[streamID, default: 0] += bucket.count
                topics[TopicKey(streamID: streamID, topic: bucket.topic ?? ""), default: 0] +=
                    bucket.count
                badge += bucket.mentionCount
            } else {
                var participants = Set(bucket.userIDs.filter { $0 > 0 && $0 != selfUserID })
                if participants.isEmpty {
                    participants = [selfUserID]
                }
                if participants.count == 1, let only = participants.first {
                    directMessages[only, default: 0] += bucket.count
                }
                badge += bucket.count
            }
        }
    }

    func unreadCount(streamID: Int64) -> Int {
        channels[streamID] ?? 0
    }

    func unreadCount(streamID: Int64, topic: String) -> Int {
        topics[TopicKey(streamID: streamID, topic: topic)] ?? 0
    }

    func unreadCount(directMessageWith userID: Int64) -> Int {
        directMessages[userID] ?? 0
    }
}
