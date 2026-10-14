import Foundation
import ZulipCoreBindings

/// Where activating a notification should take the user.
struct NotificationRoute: Equatable, Sendable {
    let key: ConversationKey
    let messageID: Int64

    private struct Payload: Codable {
        let kind: String
        let accountID: String
        let streamID: Int64?
        let topic: String?
        let recipientIDs: [Int64]?
        let messageID: Int64
    }

    /// A string safe to place in a notification's `userInfo`.
    var encoded: String? {
        let payload: Payload
        switch key {
        case let .channel(accountID, streamID):
            payload = Payload(
                kind: "channel",
                accountID: accountID,
                streamID: streamID,
                topic: nil,
                recipientIDs: nil,
                messageID: messageID
            )
        case let .topic(accountID, streamID, topic):
            payload = Payload(
                kind: "topic",
                accountID: accountID,
                streamID: streamID,
                topic: topic,
                recipientIDs: nil,
                messageID: messageID
            )
        case let .directMessage(accountID, recipientIDs):
            payload = Payload(
                kind: "dm",
                accountID: accountID,
                streamID: nil,
                topic: nil,
                recipientIDs: recipientIDs,
                messageID: messageID
            )
        default:
            return nil
        }
        guard let data = try? JSONEncoder().encode(payload) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    init(key: ConversationKey, messageID: Int64) {
        self.key = key
        self.messageID = messageID
    }

    init?(encoded: String) {
        guard let data = encoded.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return nil
        }
        switch payload.kind {
        case "channel":
            guard let streamID = payload.streamID else { return nil }
            key = .channel(accountID: payload.accountID, streamID: streamID)
        case "topic":
            guard let streamID = payload.streamID, let topic = payload.topic else {
                return nil
            }
            key = .topic(accountID: payload.accountID, streamID: streamID, topic: topic)
        case "dm":
            guard let recipientIDs = payload.recipientIDs else { return nil }
            key = .directMessage(accountID: payload.accountID, recipientIDs: recipientIDs)
        default:
            return nil
        }
        messageID = payload.messageID
    }
}

struct MessageNotification: Equatable, Sendable {
    let title: String
    let body: String
    let route: NotificationRoute
}

/// Decides which newly arrived messages deserve a local notification.
///
/// Direct messages and @-mentions notify, as do all messages in channels the
/// user asked Zulip to notify about (their own channel setting, or the
/// account-wide default) and in followed topics. Muted channels and topics
/// stay silent except for a mention of the user by name, as in Zulip; the
/// user's own messages and already-read messages never notify. The first
/// snapshot only records what already exists.
struct NotificationPlanner {
    static let maximumPerBatch = 5
    static let maximumBodyLength = 140

    private var knownMessageIDs = Set<Int64>()
    private var isPrimed = false

    /// Records existing messages without notifying (cache load, session start).
    mutating func prime(with snapshot: LiveSnapshot) {
        knownMessageIDs.formUnion(snapshot.messages.map(\.messageID))
        isPrimed = true
    }

    mutating func reset() {
        knownMessageIDs = []
        isPrimed = false
    }

    mutating func plan(
        snapshot: LiveSnapshot,
        identity: LiveSessionIdentity
    ) -> [MessageNotification] {
        guard isPrimed else {
            prime(with: snapshot)
            return []
        }
        let fresh = snapshot.messages
            .filter { !knownMessageIDs.contains($0.messageID) }
            .sorted { $0.messageID < $1.messageID }
        knownMessageIDs.formUnion(fresh.map(\.messageID))

        let settings = ChannelNotificationSettings(snapshot: snapshot)
        let channelNames = Dictionary(
            snapshot.channels.map { ($0.streamID, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        return fresh
            .filter { message in
                guard message.senderID != identity.userID,
                      !message.flags.contains("read")
                else {
                    return false
                }
                if let streamID = message.streamID {
                    return settings.notifies(
                        streamID: streamID,
                        topic: message.topic,
                        isPersonalMention: message.flags.contains("mentioned"),
                        isWildcardMention: message.flags.contains("wildcard_mentioned")
                    )
                }
                return true
            }
            .suffix(Self.maximumPerBatch)
            .map { message in
                MessageNotification(
                    title: Self.title(for: message, channelNames: channelNames),
                    body: Self.body(for: message),
                    route: NotificationRoute(
                        key: Self.conversationKey(for: message, identity: identity),
                        messageID: message.messageID
                    )
                )
            }
    }

    static func isMention(_ message: LiveMessageSnapshot) -> Bool {
        message.flags.contains("mentioned") || message.flags.contains("wildcard_mentioned")
    }

    static func conversationKey(
        for message: LiveMessageSnapshot,
        identity: LiveSessionIdentity
    ) -> ConversationKey {
        if let streamID = message.streamID {
            if let topic = message.topic {
                return .topic(accountID: identity.accountID, streamID: streamID, topic: topic)
            }
            return .channel(accountID: identity.accountID, streamID: streamID)
        }
        var recipients = Array(
            Set(message.recipientIDs.filter { $0 > 0 && $0 != identity.userID })
        ).sorted()
        if recipients.isEmpty {
            recipients = [identity.userID]
        }
        return .directMessage(accountID: identity.accountID, recipientIDs: recipients)
    }

    private static func title(
        for message: LiveMessageSnapshot,
        channelNames: [Int64: String]
    ) -> String {
        guard let streamID = message.streamID else {
            return message.senderFullName
        }
        let channel = channelNames[streamID].map { "#\($0)" } ?? "a channel"
        if let topic = message.topic, !topic.isEmpty {
            return "\(message.senderFullName) in \(channel) › \(topic)"
        }
        return "\(message.senderFullName) in \(channel)"
    }

    private static func body(for message: LiveMessageSnapshot) -> String {
        let text = message.content
            .map(\.plainText)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard text.count > maximumBodyLength else {
            return text
        }
        return String(text.prefix(maximumBodyLength - 1)) + "…"
    }
}
