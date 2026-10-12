import Foundation

/// A user supplied by the live Rust snapshot.
public struct LiveUserSnapshot: Equatable, Sendable {
    public let userID: Int64
    public let fullName: String
    public let email: String?
    public let isActive: Bool
    public let isBot: Bool

    public init(
        userID: Int64,
        fullName: String,
        email: String?,
        isActive: Bool,
        isBot: Bool
    ) {
        self.userID = userID
        self.fullName = fullName
        self.email = email
        self.isActive = isActive
        self.isBot = isBot
    }
}

/// A channel supplied by the live Rust snapshot.
public struct LiveChannelSnapshot: Equatable, Sendable {
    public let streamID: Int64
    public let name: String
    public let colorHex: String
    public let isMuted: Bool

    public init(streamID: Int64, name: String, colorHex: String, isMuted: Bool) {
        self.streamID = streamID
        self.name = name
        self.colorHex = colorHex
        self.isMuted = isMuted
    }
}

/// A topic supplied by the authenticated Rust topic directory.
public struct LiveTopicSnapshot: Equatable, Sendable {
    public let streamID: Int64
    public let name: String
    public let maxMessageID: Int64

    public init(streamID: Int64, name: String, maxMessageID: Int64) {
        self.streamID = streamID
        self.name = name
        self.maxMessageID = maxMessageID
    }
}

/// A live message whose untrusted HTML has already been normalized by Rust.
public struct LiveMessageSnapshot: Equatable, Sendable {
    public let messageID: Int64
    public let senderID: Int64
    public let senderFullName: String
    public let timestamp: Date
    public let content: [ContentBlock]
    public let streamID: Int64?
    public let topic: String?
    public let recipientIDs: [Int64]
    public let flags: [String]
    public let reactions: [LiveReactionSnapshot]

    public init(
        messageID: Int64,
        senderID: Int64,
        senderFullName: String,
        timestamp: Date,
        content: [ContentBlock],
        streamID: Int64?,
        topic: String?,
        recipientIDs: [Int64],
        flags: [String] = [],
        reactions: [LiveReactionSnapshot] = []
    ) {
        self.messageID = messageID
        self.senderID = senderID
        self.senderFullName = senderFullName
        self.timestamp = timestamp
        self.content = content
        self.streamID = streamID
        self.topic = topic
        self.recipientIDs = recipientIDs
        self.flags = flags
        self.reactions = reactions
    }
}

public struct LiveReactionSnapshot: Equatable, Sendable {
    public let emojiName: String
    public let userID: Int64

    public init(emojiName: String, userID: Int64) {
        self.emojiName = emojiName
        self.userID = userID
    }
}

/// Immutable live state emitted after register or a changed event batch.
public struct LiveSnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let lastEventID: Int64
    public let users: [LiveUserSnapshot]
    public let channels: [LiveChannelSnapshot]
    public let topics: [LiveTopicSnapshot]
    public let messages: [LiveMessageSnapshot]

    public init(
        revision: UInt64,
        lastEventID: Int64,
        users: [LiveUserSnapshot],
        channels: [LiveChannelSnapshot],
        topics: [LiveTopicSnapshot] = [],
        messages: [LiveMessageSnapshot]
    ) {
        self.revision = revision
        self.lastEventID = lastEventID
        self.users = users
        self.channels = channels
        self.topics = topics
        self.messages = messages
    }
}

/// Newest live messages for one stable conversation.
public struct LiveConversationPage: Equatable, Sendable {
    public let key: ConversationKey
    public let messages: [LiveMessageSnapshot]
    public let foundOldest: Bool
    public let foundNewest: Bool

    public init(
        key: ConversationKey,
        messages: [LiveMessageSnapshot],
        foundOldest: Bool,
        foundNewest: Bool
    ) {
        self.key = key
        self.messages = messages
        self.foundOldest = foundOldest
        self.foundNewest = foundNewest
    }
}

/// One immutable result from Zulip's authenticated server-side search.
public struct LiveSearchResult: Equatable, Sendable {
    public let key: ConversationKey
    public let message: LiveMessageSnapshot

    public init(key: ConversationKey, message: LiveMessageSnapshot) {
        self.key = key
        self.message = message
    }
}

public enum LiveTopicPropagation: Equatable, Sendable {
    case changeOne
    case changeAll
}

public enum LiveMessageFlag: Equatable, Sendable {
    case read
    case starred
}

public struct LiveTopicUpdate: Equatable, Sendable {
    public let accountID: String
    public let streamID: Int64
    public let oldTopic: String
    public let newTopic: String
    public let messageID: Int64
    public let propagation: LiveTopicPropagation

    public init(
        accountID: String,
        streamID: Int64,
        oldTopic: String,
        newTopic: String,
        messageID: Int64,
        propagation: LiveTopicPropagation
    ) {
        self.accountID = accountID
        self.streamID = streamID
        self.oldTopic = oldTopic
        self.newTopic = newTopic
        self.messageID = messageID
        self.propagation = propagation
    }
}

public struct LiveUploadedAttachment: Equatable, Sendable {
    public let accountID: String
    public let filename: String
    public let url: String
    public let markdown: String

    public init(accountID: String, filename: String, url: String, markdown: String) {
        self.accountID = accountID
        self.filename = filename
        self.url = url
        self.markdown = markdown
    }
}

public struct LiveCachedMedia: Equatable, Sendable {
    public let accountID: String
    public let remoteURL: String
    public let localURL: String
    public let contentType: String?
    public let byteCount: UInt64
    public let cacheHit: Bool

    public init(
        accountID: String,
        remoteURL: String,
        localURL: String,
        contentType: String?,
        byteCount: UInt64,
        cacheHit: Bool
    ) {
        self.accountID = accountID
        self.remoteURL = remoteURL
        self.localURL = localURL
        self.contentType = contentType
        self.byteCount = byteCount
        self.cacheHit = cacheHit
    }
}

/// Authenticated identity used by the live presentation layer.
public struct LiveSessionIdentity: Equatable, Sendable {
    public let accountID: String
    public let serverURL: String
    public let email: String
    public let userID: Int64
    public let fullName: String

    public init(
        accountID: String,
        serverURL: String,
        email: String,
        userID: Int64,
        fullName: String
    ) {
        self.accountID = accountID
        self.serverURL = serverURL
        self.email = email
        self.userID = userID
        self.fullName = fullName
    }
}

/// Stable application-facing commands sent synchronously to the Rust actor.
public enum BridgeCommand: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case ping(requestID: UInt64, payload: String)
    case startAPIKeySession(
        requestID: UInt64,
        accountID: String,
        serverURL: String,
        email: String,
        apiKey: String
    )
    case startPasswordSession(
        requestID: UInt64,
        accountID: String,
        serverURL: String,
        username: String,
        password: String
    )
    case openConversation(requestID: UInt64, key: ConversationKey, limit: UInt16)
    case loadOlderMessages(
        requestID: UInt64,
        key: ConversationKey,
        beforeMessageID: Int64,
        limit: UInt16
    )
    case searchMessages(
        requestID: UInt64,
        accountID: String,
        query: String,
        limit: UInt16
    )
    case openMessage(
        requestID: UInt64,
        key: ConversationKey,
        messageID: Int64,
        numBefore: UInt16,
        numAfter: UInt16
    )
    case sendChannelMessage(
        requestID: UInt64,
        accountID: String,
        streamID: Int64,
        topic: String,
        content: String,
        localID: String
    )
    case sendDirectMessage(
        requestID: UInt64,
        accountID: String,
        recipientIDs: [Int64],
        content: String,
        localID: String
    )
    case editMessage(
        requestID: UInt64,
        accountID: String,
        messageID: Int64,
        content: String
    )
    case deleteMessage(requestID: UInt64, accountID: String, messageID: Int64)
    case updateReaction(
        requestID: UInt64,
        accountID: String,
        messageID: Int64,
        emojiName: String,
        add: Bool
    )
    case updateMessageFlag(
        requestID: UInt64,
        accountID: String,
        messageIDs: [Int64],
        flag: LiveMessageFlag,
        add: Bool
    )
    case renameTopic(
        requestID: UInt64,
        key: ConversationKey,
        messageID: Int64,
        newTopic: String
    )
    case moveMessageToTopic(
        requestID: UInt64,
        key: ConversationKey,
        messageID: Int64,
        newTopic: String
    )
    case uploadAttachment(
        requestID: UInt64,
        accountID: String,
        localPath: String,
        filename: String
    )
    case loadMedia(requestID: UInt64, accountID: String, remoteURL: String)
    case markRead(requestID: UInt64, accountID: String, messageIDs: [Int64])
    case disconnect(requestID: UInt64)

    /// Backward-compatible foundation ping initializer.
    public init(requestID: UInt64, payload: String) {
        self = .ping(requestID: requestID, payload: payload)
    }

    public var requestID: UInt64 {
        switch self {
        case let .ping(requestID, _),
             let .startAPIKeySession(requestID, _, _, _, _),
             let .startPasswordSession(requestID, _, _, _, _),
             let .openConversation(requestID, _, _),
             let .loadOlderMessages(requestID, _, _, _),
             let .searchMessages(requestID, _, _, _),
             let .openMessage(requestID, _, _, _, _),
             let .sendChannelMessage(requestID, _, _, _, _, _),
             let .sendDirectMessage(requestID, _, _, _, _),
             let .editMessage(requestID, _, _, _),
             let .deleteMessage(requestID, _, _),
             let .updateReaction(requestID, _, _, _, _),
             let .updateMessageFlag(requestID, _, _, _, _),
             let .renameTopic(requestID, _, _, _),
             let .moveMessageToTopic(requestID, _, _, _),
             let .uploadAttachment(requestID, _, _, _),
             let .loadMedia(requestID, _, _),
             let .markRead(requestID, _, _),
             let .disconnect(requestID):
            requestID
        }
    }

    public var description: String {
        switch self {
        case .ping:
            "BridgeCommand.ping"
        case .startAPIKeySession:
            "BridgeCommand.startAPIKeySession(apiKey: [REDACTED])"
        case .startPasswordSession:
            "BridgeCommand.startPasswordSession(password: [REDACTED])"
        case .openConversation:
            "BridgeCommand.openConversation"
        case .loadOlderMessages:
            "BridgeCommand.loadOlderMessages"
        case .searchMessages:
            "BridgeCommand.searchMessages"
        case .openMessage:
            "BridgeCommand.openMessage"
        case .sendChannelMessage:
            "BridgeCommand.sendChannelMessage"
        case .sendDirectMessage:
            "BridgeCommand.sendDirectMessage"
        case .editMessage:
            "BridgeCommand.editMessage"
        case .deleteMessage:
            "BridgeCommand.deleteMessage"
        case .updateReaction:
            "BridgeCommand.updateReaction"
        case .updateMessageFlag:
            "BridgeCommand.updateMessageFlag"
        case .renameTopic:
            "BridgeCommand.renameTopic"
        case .moveMessageToTopic:
            "BridgeCommand.moveMessageToTopic"
        case .uploadAttachment:
            "BridgeCommand.uploadAttachment(localPath: [REDACTED])"
        case .loadMedia:
            "BridgeCommand.loadMedia"
        case .markRead:
            "BridgeCommand.markRead"
        case .disconnect:
            "BridgeCommand.disconnect"
        }
    }

    public var debugDescription: String { description }

    fileprivate func ffiValue() throws -> CoreCommand {
        switch self {
        case let .ping(requestID, payload):
            .ping(requestId: requestID, payload: payload)
        case let .startAPIKeySession(requestID, accountID, serverURL, email, apiKey):
            .startApiKeySession(
                requestId: requestID,
                accountId: accountID,
                serverUrl: serverURL,
                email: email,
                apiKey: apiKey
            )
        case let .startPasswordSession(requestID, accountID, serverURL, username, password):
            .startPasswordSession(
                requestId: requestID,
                accountId: accountID,
                serverUrl: serverURL,
                username: username,
                password: password
            )
        case let .openConversation(requestID, key, limit):
            .openConversation(
                requestId: requestID,
                key: try key.ffiValue(),
                limit: limit
            )
        case let .loadOlderMessages(requestID, key, beforeMessageID, limit):
            .loadOlderMessages(
                requestId: requestID,
                key: try key.ffiValue(),
                beforeMessageId: beforeMessageID,
                limit: limit
            )
        case let .searchMessages(requestID, accountID, query, limit):
            .searchMessages(
                requestId: requestID,
                accountId: accountID,
                query: query,
                limit: limit
            )
        case let .openMessage(requestID, key, messageID, numBefore, numAfter):
            .openMessage(
                requestId: requestID,
                key: try key.ffiValue(),
                messageId: messageID,
                numBefore: numBefore,
                numAfter: numAfter
            )
        case let .sendChannelMessage(
            requestID,
            accountID,
            streamID,
            topic,
            content,
            localID
        ):
            .sendChannelMessage(
                requestId: requestID,
                accountId: accountID,
                streamId: streamID,
                topic: topic,
                content: content,
                localId: localID
            )
        case let .sendDirectMessage(
            requestID,
            accountID,
            recipientIDs,
            content,
            localID
        ):
            .sendDirectMessage(
                requestId: requestID,
                accountId: accountID,
                recipientIds: recipientIDs,
                content: content,
                localId: localID
            )
        case let .editMessage(requestID, accountID, messageID, content):
            .editMessage(
                requestId: requestID,
                accountId: accountID,
                messageId: messageID,
                content: content
            )
        case let .deleteMessage(requestID, accountID, messageID):
            .deleteMessage(
                requestId: requestID,
                accountId: accountID,
                messageId: messageID
            )
        case let .updateReaction(requestID, accountID, messageID, emojiName, add):
            .updateReaction(
                requestId: requestID,
                accountId: accountID,
                messageId: messageID,
                emojiName: emojiName,
                add: add
            )
        case let .updateMessageFlag(requestID, accountID, messageIDs, flag, add):
            .updateMessageFlag(
                requestId: requestID,
                accountId: accountID,
                messageIds: messageIDs,
                flag: flag == .read ? .read : .starred,
                add: add
            )
        case let .renameTopic(requestID, key, messageID, newTopic):
            .renameTopic(
                requestId: requestID,
                key: try key.ffiValue(),
                messageId: messageID,
                newTopic: newTopic
            )
        case let .moveMessageToTopic(requestID, key, messageID, newTopic):
            .moveMessageToTopic(
                requestId: requestID,
                key: try key.ffiValue(),
                messageId: messageID,
                newTopic: newTopic
            )
        case let .uploadAttachment(requestID, accountID, localPath, filename):
            .uploadAttachment(
                requestId: requestID,
                accountId: accountID,
                localPath: localPath,
                filename: filename
            )
        case let .loadMedia(requestID, accountID, remoteURL):
            .loadMedia(
                requestId: requestID,
                accountId: accountID,
                remoteUrl: remoteURL
            )
        case let .markRead(requestID, accountID, messageIDs):
            .markRead(
                requestId: requestID,
                accountId: accountID,
                messageIds: messageIDs
            )
        case let .disconnect(requestID):
            .disconnect(requestId: requestID)
        }
    }
}

/// Stable application-facing events emitted by the Rust actor.
public enum BridgeEvent:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    case pong(requestID: UInt64, message: String)
    case sessionStarted(
        requestID: UInt64,
        identity: LiveSessionIdentity,
        credential: StoredAPICredential,
        snapshot: LiveSnapshot
    )
    case snapshotUpdated(accountID: String, snapshot: LiveSnapshot)
    case conversationOpened(requestID: UInt64, page: LiveConversationPage)
    case conversationHistoryLoaded(requestID: UInt64, page: LiveConversationPage)
    case searchCompleted(
        requestID: UInt64,
        accountID: String,
        results: [LiveSearchResult]
    )
    case messageFocused(
        requestID: UInt64,
        messageID: Int64,
        page: LiveConversationPage
    )
    case messageSent(requestID: UInt64, localID: String, messageID: Int64)
    case attachmentUploaded(requestID: UInt64, attachment: LiveUploadedAttachment)
    case mediaReady(requestID: UInt64, media: LiveCachedMedia)
    case messageEdited(requestID: UInt64, messageID: Int64, content: String)
    case messageDeleted(requestID: UInt64, messageID: Int64)
    case reactionUpdated(
        requestID: UInt64,
        messageID: Int64,
        emojiName: String,
        added: Bool
    )
    case messageFlagUpdated(
        requestID: UInt64,
        messageIDs: [Int64],
        flag: LiveMessageFlag,
        added: Bool
    )
    case topicUpdated(requestID: UInt64, update: LiveTopicUpdate)
    case messagesMarkedRead(requestID: UInt64, messageIDs: [Int64])
    case retryScheduled(accountID: String, delayMilliseconds: UInt64)
    case syncResumed(accountID: String)
    case disconnected(requestID: UInt64)
    case failed(requestID: UInt64?, message: String)

    public var requestID: UInt64 {
        switch self {
        case let .pong(requestID, _),
             let .sessionStarted(requestID, _, _, _),
             let .conversationOpened(requestID, _),
             let .conversationHistoryLoaded(requestID, _),
             let .searchCompleted(requestID, _, _),
             let .messageFocused(requestID, _, _),
             let .messageSent(requestID, _, _),
             let .attachmentUploaded(requestID, _),
             let .mediaReady(requestID, _),
             let .messageEdited(requestID, _, _),
             let .messageDeleted(requestID, _),
             let .reactionUpdated(requestID, _, _, _),
             let .messageFlagUpdated(requestID, _, _, _),
             let .topicUpdated(requestID, _),
             let .messagesMarkedRead(requestID, _),
             let .disconnected(requestID):
            requestID
        case let .failed(requestID, _):
            requestID ?? 0
        case .snapshotUpdated, .retryScheduled, .syncResumed:
            0
        }
    }

    public var message: String {
        switch self {
        case let .pong(_, message), let .failed(_, message):
            message
        case .sessionStarted:
            "Live session started"
        case .snapshotUpdated:
            "Live snapshot updated"
        case .conversationOpened:
            "Conversation opened"
        case .conversationHistoryLoaded:
            "Conversation history loaded"
        case .searchCompleted:
            "Message search completed"
        case .messageFocused:
            "Message focused"
        case .messageSent:
            "Message sent"
        case .attachmentUploaded:
            "Attachment uploaded"
        case .mediaReady:
            "Media ready"
        case .messageEdited:
            "Message edited"
        case .messageDeleted:
            "Message deleted"
        case .reactionUpdated:
            "Reaction updated"
        case .messageFlagUpdated:
            "Message flag updated"
        case .topicUpdated:
            "Topic updated"
        case .messagesMarkedRead:
            "Messages marked read"
        case .retryScheduled:
            "Retry scheduled"
        case .syncResumed:
            "Sync resumed"
        case .disconnected:
            "Disconnected"
        }
    }

    public var description: String {
        switch self {
        case .sessionStarted:
            "BridgeEvent.sessionStarted(credential: [REDACTED])"
        default:
            "BridgeEvent.\(message)"
        }
    }

    public var debugDescription: String { description }
}

/// The UI-facing core boundary shared by preview and live implementations.
public protocol CoreClientProtocol: Sendable {
    var events: AsyncStream<BridgeEvent> { get }
    func submit(_ command: BridgeCommand)
}

private final class EventRelay: CoreEventSink, @unchecked Sendable {
    private let continuation: AsyncStream<BridgeEvent>.Continuation

    init(continuation: AsyncStream<BridgeEvent>.Continuation) {
        self.continuation = continuation
    }

    func handleEvent(event: CoreEvent) {
        continuation.yield(BridgeEvent(event))
    }

    func yield(_ event: BridgeEvent) {
        continuation.yield(event)
    }

    deinit {
        continuation.finish()
    }
}

/// UniFFI-backed implementation used by the application.
public final class LiveCoreClient: CoreClientProtocol, @unchecked Sendable {
    public let events: AsyncStream<BridgeEvent>

    private let eventRelay: EventRelay
    private let rustClient: RustCoreClient

    public init() {
        let streamPair = AsyncStream<BridgeEvent>.makeStream()
        let eventRelay = EventRelay(continuation: streamPair.continuation)

        events = streamPair.stream
        self.eventRelay = eventRelay
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let mediaCacheRoot = caches
            .appendingPathComponent("io.github.huahai.ZulipMac", isDirectory: true)
            .appendingPathComponent("Media", isDirectory: true)
        rustClient = RustCoreClient(
            eventSink: eventRelay,
            mediaCacheRootPath: mediaCacheRoot.path
        )
    }

    public func submit(_ command: BridgeCommand) {
        do {
            rustClient.submit(command: try command.ffiValue())
        } catch {
            eventRelay.yield(
                .failed(requestID: command.requestID, message: error.localizedDescription)
            )
        }
    }
}

private enum BridgeMappingError: LocalizedError {
    case unsupportedConversation

    var errorDescription: String? {
        "This conversation is not available in the current live milestone."
    }
}

private extension ConversationKey {
    func ffiValue() throws -> CoreConversationKey {
        switch self {
        case let .inbox(accountID):
            .inbox(accountId: accountID)
        case let .mentions(accountID):
            .mentions(accountId: accountID)
        case let .starred(accountID):
            .starred(accountId: accountID)
        case let .unread(accountID):
            .unread(accountId: accountID)
        case let .channel(accountID, streamID):
            .channel(accountId: accountID, streamId: streamID)
        case let .topic(accountID, streamID, topic):
            .topic(accountId: accountID, streamId: streamID, topic: topic)
        case let .directMessage(accountID, recipientIDs):
            .directMessage(accountId: accountID, recipientIds: recipientIDs)
        case .drafts:
            throw BridgeMappingError.unsupportedConversation
        }
    }

    init(_ value: CoreConversationKey) {
        switch value {
        case let .inbox(accountID):
            self = .inbox(accountID: accountID)
        case let .mentions(accountID):
            self = .mentions(accountID: accountID)
        case let .starred(accountID):
            self = .starred(accountID: accountID)
        case let .unread(accountID):
            self = .unread(accountID: accountID)
        case let .channel(accountID, streamID):
            self = .channel(accountID: accountID, streamID: streamID)
        case let .topic(accountID, streamID, topic):
            self = .topic(accountID: accountID, streamID: streamID, topic: topic)
        case let .directMessage(accountID, recipientIDs):
            self = .directMessage(accountID: accountID, recipientIDs: recipientIDs)
        }
    }
}

private extension LiveSnapshot {
    init(_ snapshot: CoreSnapshot) {
        revision = snapshot.revision
        lastEventID = snapshot.lastEventId
        users = snapshot.users.map(LiveUserSnapshot.init)
        channels = snapshot.channels.map(LiveChannelSnapshot.init)
        topics = snapshot.topics.map(LiveTopicSnapshot.init)
        messages = snapshot.messages.map(LiveMessageSnapshot.init)
    }
}

private extension LiveUserSnapshot {
    init(_ user: CoreUser) {
        userID = user.userId
        fullName = user.fullName
        email = user.email
        isActive = user.isActive
        isBot = user.isBot
    }
}

private extension LiveChannelSnapshot {
    init(_ channel: CoreChannel) {
        streamID = channel.streamId
        name = channel.name
        colorHex = channel.color
        isMuted = channel.isMuted
    }
}

private extension LiveTopicSnapshot {
    init(_ topic: CoreTopic) {
        streamID = topic.streamId
        name = topic.name
        maxMessageID = topic.maxMessageId
    }
}

private extension LiveMessageSnapshot {
    init(_ message: CoreMessage) {
        messageID = message.messageId
        senderID = message.senderId
        senderFullName = message.senderFullName
        timestamp = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
        content = message.content.map(ContentBlock.init)
        streamID = message.streamId
        topic = message.topic
        recipientIDs = message.recipientIds
        flags = message.flags
        reactions = message.reactions.map {
            LiveReactionSnapshot(emojiName: $0.emojiName, userID: $0.userId)
        }
    }
}

private extension InlineContent {
    init(_ content: CoreInlineContent) {
        switch content {
        case let .text(value):
            self = .text(value)
        case let .link(label, url):
            self = .link(label: label, url: url)
        case let .mention(displayName, userID):
            self = .mention(displayName: displayName, userID: userID)
        case let .emoji(name, value):
            self = .emoji(name: name, value: value)
        }
    }
}

private extension ContentBlock {
    init(_ block: CoreContentBlock) {
        switch block {
        case let .paragraph(content):
            self = .paragraph(content.map(InlineContent.init))
        case let .quote(blocks):
            self = .quote(blocks.map(ContentBlock.init))
        case let .list(items, ordered):
            self = .list(
                items: items.map { $0.blocks.map(ContentBlock.init) },
                ordered: ordered
            )
        case let .code(language, value):
            self = .code(language: language, value: value)
        case let .image(url, alt, width, height):
            self = .image(
                url: url,
                alt: alt,
                width: width.map(Int.init),
                height: height.map(Int.init)
            )
        case let .unsupported(summary):
            self = .unsupported(summary: summary)
        }
    }
}

private extension LiveConversationPage {
    init(_ page: CoreConversationPage) {
        key = ConversationKey(page.key)
        messages = page.messages.map(LiveMessageSnapshot.init)
        foundOldest = page.foundOldest
        foundNewest = page.foundNewest
    }
}

private extension LiveSearchResult {
    init(_ result: CoreSearchResult) {
        key = ConversationKey(result.key)
        message = LiveMessageSnapshot(result.message)
    }
}

private extension BridgeEvent {
    init(_ event: CoreEvent) {
        switch event {
        case let .pong(requestID, message):
            self = .pong(requestID: requestID, message: message)
        case let .sessionStarted(
            requestID,
            accountID,
            serverURL,
            email,
            userID,
            fullName,
            credential,
            snapshot
        ):
            self = .sessionStarted(
                requestID: requestID,
                identity: LiveSessionIdentity(
                    accountID: accountID,
                    serverURL: serverURL,
                    email: email,
                    userID: userID,
                    fullName: fullName
                ),
                credential: StoredAPICredential(
                    accountID: accountID,
                    apiKey: credential.apiKey
                ),
                snapshot: LiveSnapshot(snapshot)
            )
        case let .snapshotUpdated(accountID, snapshot):
            self = .snapshotUpdated(
                accountID: accountID,
                snapshot: LiveSnapshot(snapshot)
            )
        case let .conversationOpened(requestID, page):
            self = .conversationOpened(
                requestID: requestID,
                page: LiveConversationPage(page)
            )
        case let .conversationHistoryLoaded(requestID, page):
            self = .conversationHistoryLoaded(
                requestID: requestID,
                page: LiveConversationPage(page)
            )
        case let .searchCompleted(requestID, accountID, results):
            self = .searchCompleted(
                requestID: requestID,
                accountID: accountID,
                results: results.map(LiveSearchResult.init)
            )
        case let .messageFocused(requestID, messageID, page):
            self = .messageFocused(
                requestID: requestID,
                messageID: messageID,
                page: LiveConversationPage(page)
            )
        case let .messageSent(requestID, localID, messageID):
            self = .messageSent(
                requestID: requestID,
                localID: localID,
                messageID: messageID
            )
        case let .attachmentUploaded(requestID, accountID, filename, url, markdown):
            self = .attachmentUploaded(
                requestID: requestID,
                attachment: LiveUploadedAttachment(
                    accountID: accountID,
                    filename: filename,
                    url: url,
                    markdown: markdown
                )
            )
        case let .mediaReady(
            requestID,
            accountID,
            remoteURL,
            localURL,
            contentType,
            byteCount,
            cacheHit
        ):
            self = .mediaReady(
                requestID: requestID,
                media: LiveCachedMedia(
                    accountID: accountID,
                    remoteURL: remoteURL,
                    localURL: localURL,
                    contentType: contentType,
                    byteCount: byteCount,
                    cacheHit: cacheHit
                )
            )
        case let .messageEdited(requestID, messageID, content):
            self = .messageEdited(
                requestID: requestID,
                messageID: messageID,
                content: content
            )
        case let .messageDeleted(requestID, messageID):
            self = .messageDeleted(requestID: requestID, messageID: messageID)
        case let .reactionUpdated(requestID, messageID, emojiName, added):
            self = .reactionUpdated(
                requestID: requestID,
                messageID: messageID,
                emojiName: emojiName,
                added: added
            )
        case let .messageFlagUpdated(requestID, messageIDs, flag, added):
            self = .messageFlagUpdated(
                requestID: requestID,
                messageIDs: messageIDs,
                flag: flag == .read ? .read : .starred,
                added: added
            )
        case let .topicUpdated(
            requestID,
            accountID,
            streamID,
            oldTopic,
            newTopic,
            messageID,
            propagation
        ):
            self = .topicUpdated(
                requestID: requestID,
                update: LiveTopicUpdate(
                    accountID: accountID,
                    streamID: streamID,
                    oldTopic: oldTopic,
                    newTopic: newTopic,
                    messageID: messageID,
                    propagation: propagation == .changeAll ? .changeAll : .changeOne
                )
            )
        case let .messagesMarkedRead(requestID, messageIDs):
            self = .messagesMarkedRead(
                requestID: requestID,
                messageIDs: messageIDs
            )
        case let .retryScheduled(accountID, delayMilliseconds):
            self = .retryScheduled(
                accountID: accountID,
                delayMilliseconds: delayMilliseconds
            )
        case let .syncResumed(accountID):
            self = .syncResumed(accountID: accountID)
        case let .disconnected(requestID):
            self = .disconnected(requestID: requestID)
        case let .failed(requestID, message):
            self = .failed(requestID: requestID, message: message)
        }
    }
}
