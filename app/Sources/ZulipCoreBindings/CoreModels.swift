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

public struct ChannelSnapshot: Identifiable, Equatable, Sendable {
    public let streamID: Int64
    public let name: String
    public let colorHex: String
    public let unreadCount: Int
    public let isMuted: Bool

    public var id: Int64 { streamID }

    public init(
        streamID: Int64,
        name: String,
        colorHex: String,
        unreadCount: Int = 0,
        isMuted: Bool = false
    ) {
        self.streamID = streamID
        self.name = name
        self.colorHex = colorHex
        self.unreadCount = unreadCount
        self.isMuted = isMuted
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

    public var id: Int64 { userID }

    public init(
        userID: Int64,
        displayName: String,
        initials: String,
        unreadCount: Int = 0,
        presence: PresenceState
    ) {
        self.userID = userID
        self.displayName = displayName
        self.initials = initials
        self.unreadCount = unreadCount
        self.presence = presence
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

    public init(
        accountID: String,
        organizationName: String,
        organizationHost: String,
        quickLinks: [QuickLinkSnapshot],
        channels: [ChannelSnapshot],
        directMessages: [DirectMessageSnapshot],
        currentUserName: String,
        currentUserInitials: String
    ) {
        self.accountID = accountID
        self.organizationName = organizationName
        self.organizationHost = organizationHost
        self.quickLinks = quickLinks
        self.channels = channels
        self.directMessages = directMessages
        self.currentUserName = currentUserName
        self.currentUserInitials = currentUserInitials
    }
}

public enum InlineContent: Equatable, Sendable {
    case text(String)
    case link(label: String, url: String)
    case mention(displayName: String, userID: Int64)
    case emoji(name: String, value: String)

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
        }
    }
}

public indirect enum ContentBlock: Equatable, Sendable {
    case paragraph([InlineContent])
    case quote([ContentBlock])
    case list(items: [[ContentBlock]], ordered: Bool)
    case code(language: String?, value: String)
    case image(url: String, alt: String, width: Int?, height: Int?)
    case unsupported(summary: String)

    public var plainText: String {
        switch self {
        case let .paragraph(content):
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

public struct MessageViewData: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let accountID: String
    public let conversationKey: ConversationKey
    public let senderID: Int64
    public let senderName: String
    public let senderInitials: String
    public let timestamp: Date
    public let content: [ContentBlock]
    public let isOwnMessage: Bool
    public var isStarred: Bool
    public var reactionCount: Int
    public var deliveryState: MessageDeliveryState

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
        isStarred: Bool = false,
        reactionCount: Int = 0,
        deliveryState: MessageDeliveryState = .sent
    ) {
        self.id = id
        self.accountID = accountID
        self.conversationKey = conversationKey
        self.senderID = senderID
        self.senderName = senderName
        self.senderInitials = senderInitials
        self.timestamp = timestamp
        self.content = content
        self.isOwnMessage = isOwnMessage
        self.isStarred = isStarred
        self.reactionCount = reactionCount
        self.deliveryState = deliveryState
    }

    public var plainText: String {
        content.map(\.plainText).joined(separator: "\n")
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
