import Foundation

/// Stable identity for a conversation, independent of its current display name.
public enum ConversationKey: Hashable, Sendable {
    case inbox(accountID: String)
    case mentions(accountID: String)
    case starred(accountID: String)
    case unread(accountID: String)
    case drafts(accountID: String)
    case channel(accountID: String, streamID: Int64)
    case topic(accountID: String, streamID: Int64, topic: String)
    case directMessage(accountID: String, recipientIDs: [Int64])

    public var accountID: String {
        switch self {
        case let .inbox(accountID),
             let .mentions(accountID),
             let .starred(accountID),
             let .unread(accountID),
             let .drafts(accountID),
             let .channel(accountID, _),
             let .topic(accountID, _, _),
             let .directMessage(accountID, _):
            accountID
        }
    }
}

public struct QuickLinkSnapshot: Identifiable, Equatable, Sendable {
    public let key: ConversationKey
    public let title: String
    public let systemImage: String
    public let unreadCount: Int

    public var id: ConversationKey { key }

    public init(
        key: ConversationKey,
        title: String,
        systemImage: String,
        unreadCount: Int = 0
    ) {
        self.key = key
        self.title = title
        self.systemImage = systemImage
        self.unreadCount = unreadCount
    }
}

public struct TopicSnapshot: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        public let streamID: Int64
        public let name: String

        public init(streamID: Int64, name: String) {
            self.streamID = streamID
            self.name = name
        }
    }

    public let streamID: Int64
    public let name: String
    public let maxMessageID: Int64
    public let unreadCount: Int

    public var id: ID { ID(streamID: streamID, name: name) }

    public init(streamID: Int64, name: String, maxMessageID: Int64, unreadCount: Int = 0) {
        self.streamID = streamID
        self.name = name
        self.maxMessageID = maxMessageID
        self.unreadCount = unreadCount
    }
}

public struct ChannelSnapshot: Identifiable, Equatable, Sendable {
    public let streamID: Int64
    public let name: String
    public let colorHex: String
    public let unreadCount: Int
    public let isMuted: Bool
    public let topics: [TopicSnapshot]
    /// Whether every message in the channel raises a notification: its own
    /// Zulip setting, or the account-wide default when it has none.
    public let notifiesForAllMessages: Bool

    public var id: Int64 { streamID }

    public init(
        streamID: Int64,
        name: String,
        colorHex: String,
        unreadCount: Int = 0,
        isMuted: Bool = false,
        notifiesForAllMessages: Bool = false,
        topics: [TopicSnapshot] = []
    ) {
        self.notifiesForAllMessages = notifiesForAllMessages
        self.streamID = streamID
        self.name = name
        self.colorHex = colorHex
        self.unreadCount = unreadCount
        self.isMuted = isMuted
        self.topics = topics
    }
}

public enum PresenceState: Equatable, Sendable {
    case active
    case idle
    case offline
}

public struct DirectMessageSnapshot: Identifiable, Equatable, Sendable {
    public let userID: Int64
    public let displayName: String
    public let initials: String
    public let unreadCount: Int
    public let presence: PresenceState
    public let avatarURL: String?

    public var id: Int64 { userID }

    public init(
        userID: Int64,
        displayName: String,
        initials: String,
        unreadCount: Int = 0,
        presence: PresenceState,
        avatarURL: String? = nil
    ) {
        self.userID = userID
        self.displayName = displayName
        self.initials = initials
        self.unreadCount = unreadCount
        self.presence = presence
        self.avatarURL = avatarURL
    }
}

/// Immutable data required to render the application sidebar.
public struct SidebarSnapshot: Equatable, Sendable {
    public let accountID: String
    public let organizationName: String
    public let organizationHost: String
    public let quickLinks: [QuickLinkSnapshot]
    public let channels: [ChannelSnapshot]
    public let directMessages: [DirectMessageSnapshot]
    public let currentUserName: String
    public let currentUserInitials: String
    public let organizationIconURL: String?
    public let currentUserAvatarURL: String?

    public init(
        accountID: String,
        organizationName: String,
        organizationHost: String,
        quickLinks: [QuickLinkSnapshot],
        channels: [ChannelSnapshot],
        directMessages: [DirectMessageSnapshot],
        currentUserName: String,
        currentUserInitials: String,
        organizationIconURL: String? = nil,
        currentUserAvatarURL: String? = nil
    ) {
        self.accountID = accountID
        self.organizationName = organizationName
        self.organizationHost = organizationHost
        self.quickLinks = quickLinks
        self.channels = channels
        self.directMessages = directMessages
        self.currentUserName = currentUserName
        self.currentUserInitials = currentUserInitials
        self.organizationIconURL = organizationIconURL
        self.currentUserAvatarURL = currentUserAvatarURL
    }
}

public enum InlineStyle: Equatable, Sendable {
    case strong
    case emphasis
    case strikethrough
    case code
}

public enum InlineContent: Equatable, Sendable {
    case text(String)
    case link(label: String, url: String)
    case mention(displayName: String, userID: Int64)
    case emoji(name: String, value: String)
    case styled(InlineStyle, [InlineContent])

    public var plainText: String {
        switch self {
        case let .text(value):
            value
        case let .link(label, _):
            label
        case let .mention(displayName, _):
            "@\(displayName)"
        case let .emoji(_, value):
            value
        case let .styled(_, content):
            content.map(\.plainText).joined()
        }
    }
}

public indirect enum ContentBlock: Equatable, Sendable {
    case paragraph([InlineContent])
    case heading(level: Int, content: [InlineContent])
    case quote([ContentBlock])
    case list(items: [[ContentBlock]], ordered: Bool)
    case code(language: String?, value: String)
    case image(url: String, alt: String, width: Int?, height: Int?)
    case unsupported(summary: String)

    public var plainText: String {
        switch self {
        case let .paragraph(content), let .heading(_, content):
            content.map(\.plainText).joined()
        case let .quote(blocks):
            blocks.map(\.plainText).joined(separator: "\n")
        case let .list(items, _):
            items
                .map { $0.map(\.plainText).joined(separator: " ") }
                .joined(separator: "\n")
        case let .code(_, value):
            value
        case let .image(_, alt, _, _):
            alt
        case let .unsupported(summary):
            summary
        }
    }
}

public enum MessageDeliveryState: Equatable, Sendable {
    case sent
    case pending
    case failed
}

public enum MessageActionKind: Equatable, Sendable {
    case edit
    case delete
    case reaction
    case star
    case readState
}

public enum MessageActionState: Equatable, Sendable {
    case idle
    case pending(MessageActionKind)
    case failed(MessageActionKind, message: String)
}

/// An emoji a reaction can be added with or removed by.
public struct ReactionTarget: Equatable, Sendable {
    public let name: String
    /// Dash-joined hexadecimal code points; empty when the emoji is known only by name.
    public let code: String
    public let type: String

    public init(name: String, code: String = "", type: String = "unicode_emoji") {
        self.name = name
        self.code = code
        self.type = type
    }

    /// Puts a code in one spelling: Zulip pads code points to four digits
    /// ("00a9") while emoji tables do not ("a9").
    public static func normalizedCode(_ code: String) -> String {
        code.lowercased().split(separator: "-").map { part in
            UInt32(part, radix: 16).map { String($0, radix: 16) } ?? String(part)
        }.joined(separator: "-")
    }

    /// Whether `reaction` is this emoji: same code and kind when both have a
    /// code (two names can share one emoji), otherwise the same name.
    public func matches(_ reaction: MessageReaction) -> Bool {
        if !code.isEmpty, !reaction.emojiCode.isEmpty {
            return Self.normalizedCode(code) == Self.normalizedCode(reaction.emojiCode)
                && (type.isEmpty || reaction.reactionType.isEmpty || type == reaction.reactionType)
        }
        return name == reaction.emojiName
    }
}

/// One emoji shown under a message with how many people used it.
public struct MessageReaction: Identifiable, Equatable, Sendable {
    /// The name the current user reacted with, or the first name used.
    public let emojiName: String
    /// Dash-joined hexadecimal code points of a Unicode emoji; empty when unknown.
    public let emojiCode: String
    /// `unicode_emoji`, `realm_emoji` or `zulip_extra_emoji`; empty when unknown.
    public let reactionType: String
    public var count: Int
    public var includesMe: Bool

    public init(
        emojiName: String,
        emojiCode: String = "",
        reactionType: String = "",
        count: Int = 1,
        includesMe: Bool = false
    ) {
        self.emojiName = emojiName
        self.emojiCode = emojiCode
        self.reactionType = reactionType
        self.count = count
        self.includesMe = includesMe
    }

    public var id: String {
        emojiCode.isEmpty
            ? "name:\(emojiName)"
            : "\(reactionType):\(ReactionTarget.normalizedCode(emojiCode))"
    }

    public var target: ReactionTarget {
        ReactionTarget(name: emojiName, code: emojiCode, type: reactionType)
    }
}

public struct MessageViewData: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let accountID: String
    public let conversationKey: ConversationKey
    public let senderID: Int64
    public let senderName: String
    public let senderInitials: String
    public let timestamp: Date
    public var content: [ContentBlock]
    public let isOwnMessage: Bool
    public let sourceStreamID: Int64?
    public let sourceTopic: String?
    public var isStarred: Bool
    /// Emoji reactions in the order they first appeared, one entry per emoji name.
    public var reactions: [MessageReaction]
    public var isRead: Bool
    public var deliveryState: MessageDeliveryState
    public var actionState: MessageActionState
    public var senderAvatarURL: String?
    /// Identity of the timeline row. It equals `id` except for a sent message whose
    /// server copy replaced its local echo: the copy keeps the echo's row so the
    /// row updates in place instead of being torn down and rebuilt.
    public var rowID: Int64
    /// A local echo whose final rendering belongs to the server (the text uses
    /// Markdown), so the timeline shows a placeholder until the server copy arrives.
    public var isProvisional: Bool
    /// When the content was last edited; nil for a message never edited.
    public var editedAt: Date?

    public init(
        id: Int64,
        accountID: String,
        conversationKey: ConversationKey,
        senderID: Int64,
        senderName: String,
        senderInitials: String,
        timestamp: Date,
        content: [ContentBlock],
        isOwnMessage: Bool,
        sourceStreamID: Int64? = nil,
        sourceTopic: String? = nil,
        isStarred: Bool = false,
        reactions: [MessageReaction] = [],
        isRead: Bool = true,
        deliveryState: MessageDeliveryState = .sent,
        actionState: MessageActionState = .idle,
        senderAvatarURL: String? = nil,
        isProvisional: Bool = false,
        editedAt: Date? = nil
    ) {
        self.id = id
        self.rowID = id
        self.isProvisional = isProvisional
        self.accountID = accountID
        self.conversationKey = conversationKey
        self.senderID = senderID
        self.senderName = senderName
        self.senderInitials = senderInitials
        self.timestamp = timestamp
        self.content = content
        self.isOwnMessage = isOwnMessage
        self.sourceStreamID = sourceStreamID
        self.sourceTopic = sourceTopic
        self.isStarred = isStarred
        self.reactions = reactions
        self.isRead = isRead
        self.deliveryState = deliveryState
        self.actionState = actionState
        self.senderAvatarURL = senderAvatarURL
        self.editedAt = editedAt
    }

    public var plainText: String {
        content.map(\.plainText).joined(separator: "\n")
    }

    /// The reaction group `target` belongs to, if the message has one.
    public func reaction(matching target: ReactionTarget) -> MessageReaction? {
        reactions.first { target.matches($0) }
    }

    /// Adds or removes the current user's use of `target`, keeping the counts in step.
    public mutating func applyReaction(_ target: ReactionTarget, add: Bool) {
        if let index = reactions.firstIndex(where: { target.matches($0) }) {
            if add {
                guard !reactions[index].includesMe else { return }
                reactions[index].count += 1
                reactions[index].includesMe = true
            } else {
                guard reactions[index].includesMe else { return }
                reactions[index].includesMe = false
                reactions[index].count -= 1
                if reactions[index].count <= 0 {
                    reactions.remove(at: index)
                }
            }
        } else if add {
            reactions.append(
                MessageReaction(
                    emojiName: target.name,
                    emojiCode: target.code,
                    reactionType: target.type,
                    count: 1,
                    includesMe: true
                )
            )
        }
    }
}

public struct ConversationPage: Equatable, Sendable {
    public let key: ConversationKey
    public let title: String
    public let subtitle: String
    public let messages: [MessageViewData]
    public let beforeCursor: String?
    public let afterCursor: String?
    public let focusedMessageID: Int64?

    public init(
        key: ConversationKey,
        title: String,
        subtitle: String,
        messages: [MessageViewData],
        beforeCursor: String? = nil,
        afterCursor: String? = nil,
        focusedMessageID: Int64? = nil
    ) {
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.messages = messages
        self.beforeCursor = beforeCursor
        self.afterCursor = afterCursor
        self.focusedMessageID = focusedMessageID
    }
}
