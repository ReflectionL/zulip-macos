import Foundation
import AppKit
import Observation
import OSLog
import ZulipCoreBindings

/// Session lifecycle breadcrumbs for Console.app. Only event names are public;
/// dynamic values (server messages) stay private, and credentials are never logged.
private let sessionLog = Logger(subsystem: "io.github.huahai.ZulipMac", category: "session")

enum LiveAuthenticationMethod: String, CaseIterable, Identifiable, Sendable {
    case password = "Password"
    case apiKey = "API Key"

    var id: Self { self }
}

enum LiveConnectionState: Equatable, Sendable {
    case signedOut
    case connecting
    case connected
    case retrying(delayMilliseconds: UInt64)
    case failed(message: String)

    var isConnecting: Bool {
        self == .connecting
    }
}

struct MessageSearchResult: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let accountID: String
        let messageID: Int64
    }

    let accountID: String
    let conversationKey: ConversationKey
    let messageID: Int64
    let senderName: String
    let timestamp: Date
    let contentPreview: String
    let title: String
    let subtitle: String
    let systemImage: String

    var id: ID {
        ID(accountID: accountID, messageID: messageID)
    }

    var navigationDestination: NavigationDestination {
        NavigationDestination(
            key: conversationKey,
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            keywords: []
        )
    }
}

enum MessageSearchState: Equatable, Sendable {
    case idle
    case loading(query: String)
    case loaded(query: String, results: [MessageSearchResult])
    case failed(query: String, message: String)
}

enum TopicAction: Equatable, Sendable {
    case rename(key: ConversationKey, messageID: Int64, newTopic: String)
    case move(key: ConversationKey, messageID: Int64, newTopic: String)
}

enum TopicActionState: Equatable, Sendable {
    case idle
    case working(TopicAction)
    case failed(action: TopicAction, message: String)
}

enum AttachmentUploadState: Equatable, Sendable {
    case idle
    case uploading(filename: String)
    case failed(filename: String, message: String)

    var isUploading: Bool {
        if case .uploading = self { true } else { false }
    }
}

struct ComposerAttachmentInsertion: Equatable, Sendable {
    let id: UInt64
    let key: ConversationKey
    let filename: String
    let markdown: String
    /// Set for a quote, which waits above the composer instead of entering the text.
    var quote: ComposerQuote?
}

private enum MessageAction: Equatable, Sendable {
    case edit(messageID: Int64, content: String)
    case delete(messageID: Int64)
    case reaction(messageID: Int64, add: Bool)
    case flag(messageID: Int64, flag: LiveMessageFlag, add: Bool)

    var messageID: Int64 {
        switch self {
        case let .edit(messageID, _),
             let .delete(messageID),
             let .reaction(messageID, _),
             let .flag(messageID, _, _):
            messageID
        }
    }

    var kind: MessageActionKind {
        switch self {
        case .edit: .edit
        case .delete: .delete
        case .reaction: .reaction
        case let .flag(_, flag, _): flag == .starred ? .star : .readState
        }
    }
}

private struct SubmittedMessageAction: Sendable {
    let action: MessageAction
    let priorMessage: MessageViewData
}

private struct PendingSend: Sendable {
    let key: ConversationKey
    let content: String
    let localID: String
    let localMessageID: Int64
}

/// A message whose Markdown source is being fetched to quote or forward it.
private struct PendingMessageSource: Sendable {
    enum Purpose: Sendable {
        case quote(into: ConversationKey)
        case forward(to: ConversationKey)
    }

    let purpose: Purpose
    let message: MessageViewData
}

private struct PendingAttachmentUpload: Sendable {
    let key: ConversationKey
    let fileURL: URL
    let filename: String
    let accessedSecurityScope: Bool

    func withoutSecurityScope() -> Self {
        Self(
            key: key,
            fileURL: fileURL,
            filename: filename,
            accessedSecurityScope: false
        )
    }
}

@MainActor
@Observable
final class LiveSessionViewModel {
    private static let lastServerURLKey = "lastAccount.serverURL"
    private static let lastEmailKey = "lastAccount.email"
    static let defaultServerURL = ""
    private static let conversationPageSize: UInt16 = 10
    private static let searchResultLimit: UInt16 = 20
    private static let searchContextRadius: UInt16 = 10

    var authenticationMethod = LiveAuthenticationMethod.password
    var serverURL = LiveSessionViewModel.defaultServerURL
    var email = ""
    var secret = ""
    var connectionState = LiveConnectionState.signedOut
    var notice: String?
    private(set) var identity: LiveSessionIdentity?
    private(set) var sidebarSnapshot: SidebarSnapshot?
    private(set) var navigationDirectory = NavigationDirectory(destinations: [])
    private(set) var conversationState = ConversationLoadState.loading(
        title: "Inbox",
        subtitle: "Live Zulip"
    )
    private(set) var isLoadingOlderMessages = false
    private(set) var messageSearchState = MessageSearchState.idle
    private(set) var topicActionState = TopicActionState.idle
    private(set) var requestedTopicNavigation: ConversationKey?
    private(set) var attachmentUploadState = AttachmentUploadState.idle
    private(set) var attachmentInsertion: ComposerAttachmentInsertion?
    private(set) var mediaLocalURLs: [String: String] = [:]
    private(set) var mediaFailures: [String: String] = [:]

    @ObservationIgnored private let client: any CoreClientProtocol
    @ObservationIgnored private let credentialStore: any CredentialStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifier: (any MessageNotifier)?
    @ObservationIgnored private var notificationPlanner = NotificationPlanner()
    @ObservationIgnored var isApplicationActive: () -> Bool = { NSApplication.shared.isActive }
    private var unseenNotificationCount = 0
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var cachedSessionRequestID: UInt64?
    private var hasLiveSession = false
    @ObservationIgnored private var snapshotMessages: [Int64: LiveMessageSnapshot] = [:]
    @ObservationIgnored private var avatarURLs: [Int64: String] = [:]
    /// Set while the visible page is only the local cache of that conversation, which
    /// the first fresh page replaces outright instead of merging into.
    @ObservationIgnored private var cachedPlaceholderKey: ConversationKey?
    /// Pages already shown this session, newest use last, so reopening a chat,
    /// topic or thread paints at once instead of passing through a loading state.
    @ObservationIgnored private var recentPages: [ConversationKey: ConversationPage] = [:]
    @ObservationIgnored private var recentPageOrder: [ConversationKey] = []
    private static let recentPageLimit = 24
    @ObservationIgnored private var presenceStates: [Int64: PresenceState] = [:]
    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    private(set) var drafts: [ConversationKey: String] = [:]
    @ObservationIgnored private var draftSaveTasks: [ConversationKey: Task<Void, Never>] = [:]
    private var requestID: UInt64 = 1
    private var activeSelection: ConversationKey?
    private var pendingOlderRequestID: UInt64?
    private var pendingSearchRequestID: UInt64?
    private var pendingSearchQuery: String?
    private var issuedSearchRequestIDs = Set<UInt64>()
    private var pendingFocusedMessageRequestID: UInt64?
    private var issuedFocusedMessageRequestIDs = Set<UInt64>()
    private var topicActionsByRequestID: [UInt64: TopicAction] = [:]
    @ObservationIgnored private var messageSourceRequests: [UInt64: PendingMessageSource] = [:]
    private var messageActionsByRequestID: [UInt64: SubmittedMessageAction] = [:]
    private var failedMessageActions: [Int64: MessageAction] = [:]
    private var sendsByRequestID: [UInt64: PendingSend] = [:]
    private var failedSends: [Int64: PendingSend] = [:]
    /// Server message ID -> local echo ID for sends the server accepted but whose
    /// rendered copy has not been fetched yet; the echo stays visible until then.
    private var confirmedEchoes: [Int64: Int64] = [:]
    private var attachmentUploadsByRequestID: [UInt64: PendingAttachmentUpload] = [:]
    private var failedAttachmentUpload: PendingAttachmentUpload?
    private var mediaRequestsByRequestID: [UInt64: String] = [:]
    private var pendingMediaURLs = Set<String>()
    private var knownTopics: [ConversationKey: LiveTopicSnapshot] = [:]

    init(
        client: any CoreClientProtocol = LiveCoreClient(),
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        defaults: UserDefaults = .standard,
        notifier: (any MessageNotifier)? = nil
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.defaults = defaults
        self.notifier = notifier
        notifier?.onActivate = { [weak self] route in
            self?.openFromNotification(route)
        }
        notifier?.onApplicationActivated = { [weak self] in
            self?.unseenNotificationCount = 0
        }
    }

    /// Takes the user to the conversation a notification was about.
    func openFromNotification(_ route: NotificationRoute) {
        guard identity?.accountID == route.key.accountID else {
            return
        }
        requestedTopicNavigation = route.key
    }

    private func notifyAboutNewMessages(in snapshot: LiveSnapshot) {
        guard let identity else {
            return
        }
        let notifications = notificationPlanner.plan(snapshot: snapshot, identity: identity)
        guard let notifier else {
            return
        }
        for notification in notifications {
            // Do not interrupt the conversation the user is already reading.
            if isApplicationActive(), activeSelection == notification.route.key {
                continue
            }
            notifier.post(notification)
            unseenNotificationCount += 1
        }
        if unseenNotificationCount > 0 {
            notifier.setBadge(unseenNotificationCount)
        }
    }

    func startObserving() {
        guard eventTask == nil else {
            return
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSystemWake()
            }
        }
        eventTask = Task { [weak self, client] in
            for await event in client.events {
                guard let self else {
                    return
                }
                await self.consume(event)
            }
        }
    }

    func connect() {
        startObserving()
        let trimmedServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty, !trimmedEmail.isEmpty, !secret.isEmpty else {
            connectionState = .failed(message: "Enter a server, email, and credential.")
            return
        }

        let accountID = Self.accountID(serverURL: trimmedServer, email: trimmedEmail)
        let id = nextRequestID()
        connectionState = .connecting
        notice = nil

        switch authenticationMethod {
        case .password:
            client.submit(
                .startPasswordSession(
                    requestID: id,
                    accountID: accountID,
                    serverURL: trimmedServer,
                    username: trimmedEmail,
                    password: secret
                )
            )
        case .apiKey:
            client.submit(
                .startAPIKeySession(
                    requestID: id,
                    accountID: accountID,
                    serverURL: trimmedServer,
                    email: trimmedEmail,
                    apiKey: secret
                )
            )
        }
        secret = ""
    }

    func connectUsingSavedAPIKey() async {
        await connectUsingSavedAPIKey(reportMissingKey: true)
    }

    /// Reconnects the account that was active when the app last ran, so a
    /// relaunch does not require signing in again. Does nothing when the user
    /// disconnected on purpose or no API key is stored.
    func restoreSavedSession() async {
        guard identity == nil,
              !connectionState.isConnecting,
              let savedServer = defaults.string(forKey: Self.lastServerURLKey),
              let savedEmail = defaults.string(forKey: Self.lastEmailKey)
        else {
            return
        }
        serverURL = savedServer
        email = savedEmail
        startObserving()
        // Show the last known state immediately; the live session replaces it.
        let cachedRequestID = nextRequestID()
        cachedSessionRequestID = cachedRequestID
        client.submit(
            .loadCachedSession(
                requestID: cachedRequestID,
                accountID: Self.accountID(serverURL: savedServer, email: savedEmail)
            )
        )
        await connectUsingSavedAPIKey(reportMissingKey: false)
    }

    /// True for failures that mean "the network is unavailable" rather than
    /// "the server rejected us". The text mirrors the Rust core's sanitized
    /// transport errors.
    static func isTransientFailure(_ message: String) -> Bool {
        message.hasPrefix("could not connect securely")
            || message.hasPrefix("could not synchronize")
            || message.hasPrefix("authentication returned HTTP 5")
            || message.hasPrefix("event synchronization returned HTTP 5")
    }

    /// Whether the visible data may be older than the server's: either no live
    /// session exists yet, or the live session is currently retrying.
    private var isServingCachedData: Bool {
        if !hasLiveSession {
            return true
        }
        if case .retrying = connectionState {
            return true
        }
        return false
    }

    /// After sleep the server has usually dropped the event queue and a pending
    /// backoff timer may be minutes away, so retry immediately.
    func handleSystemWake() {
        guard identity != nil, case .retrying = connectionState else {
            return
        }
        sessionLog.info("system woke while offline; reconnecting now")
        reconnectNow()
    }

    /// Manual "Reconnect" from the offline banner.
    func reconnectNow() {
        if hasLiveSession {
            if let activeSelection {
                refreshConversation(activeSelection)
            }
            return
        }
        cancelReconnect()
        Task { await connectUsingSavedAPIKey(reportMissingKey: false) }
    }

    func draft(for key: ConversationKey) -> String {
        drafts[key] ?? ""
    }

    /// Remembers composer text immediately and persists it shortly after typing
    /// pauses, so a relaunch or conversation switch never loses it.
    func updateDraft(_ content: String, for key: ConversationKey) {
        guard identity?.accountID == key.accountID else {
            return
        }
        if content.isEmpty {
            drafts.removeValue(forKey: key)
        } else {
            drafts[key] = content
        }
        draftSaveTasks[key]?.cancel()
        draftSaveTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.draftSaveTasks.removeValue(forKey: key)
            self.client.submit(
                .saveDraft(requestID: self.nextRequestID(), key: key, content: content)
            )
        }
    }

    private func loadDrafts(for accountID: String) {
        client.submit(.loadDrafts(requestID: nextRequestID(), accountID: accountID))
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let seconds = min(5 << min(reconnectAttempt, 4), 60)
        reconnectAttempt += 1
        sessionLog.info("offline; reconnect attempt \(self.reconnectAttempt, privacy: .public) in \(seconds, privacy: .public) s")
        connectionState = .retrying(delayMilliseconds: UInt64(seconds) * 1_000)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.connectUsingSavedAPIKey(reportMissingKey: false)
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
    }

    private func connectUsingSavedAPIKey(reportMissingKey: Bool) async {
        startObserving()
        let trimmedServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty, !trimmedEmail.isEmpty else {
            connectionState = .failed(message: "Enter the saved account’s server and email.")
            return
        }

        let accountID = Self.accountID(serverURL: trimmedServer, email: trimmedEmail)
        do {
            let credential = try await credentialStore.load(accountID: accountID)
            authenticationMethod = .apiKey
            connectionState = .connecting
            notice = nil
            client.submit(
                .startAPIKeySession(
                    requestID: nextRequestID(),
                    accountID: accountID,
                    serverURL: trimmedServer,
                    email: trimmedEmail,
                    apiKey: credential.apiKey
                )
            )
        } catch {
            if reportMissingKey {
                connectionState = .failed(message: "No saved API key was found for this account.")
            }
        }
    }

    private func rememberLastAccount(_ identity: LiveSessionIdentity) {
        defaults.set(identity.serverURL, forKey: Self.lastServerURLKey)
        defaults.set(identity.email, forKey: Self.lastEmailKey)
    }

    private func forgetLastAccount() {
        defaults.removeObject(forKey: Self.lastServerURLKey)
        defaults.removeObject(forKey: Self.lastEmailKey)
    }

    func openConversation(_ key: ConversationKey) {
        guard identity?.accountID == key.accountID else {
            return
        }
        stashVisiblePage()
        pendingFocusedMessageRequestID = nil
        pendingOlderRequestID = nil
        isLoadingOlderMessages = false
        activeSelection = key
        if let page = recentPages[key] {
            // Seen earlier this session: show it synchronously while the fresh page loads.
            cachedPlaceholderKey = key
            conversationState = isServingCachedData ? .offline(page) : .loaded(page)
        } else {
            let destination = navigationDirectory.destination(for: key)
            conversationState = .loading(
                title: destination?.title ?? "Conversation",
                subtitle: destination?.subtitle ?? organizationName
            )
            // Otherwise show the last on-disk copy as soon as the core reads it.
            cachedPlaceholderKey = nil
        }
        client.submit(.loadCachedConversation(requestID: nextRequestID(), key: key))
        client.submit(
            .openConversation(
                requestID: nextRequestID(),
                key: key,
                limit: Self.conversationPageSize
            )
        )
    }

    func searchMessages(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identity else {
            messageSearchState = .failed(
                query: query,
                message: "Connect to Zulip before searching messages."
            )
            return
        }
        guard !query.isEmpty else {
            clearMessageSearch()
            return
        }

        let id = nextRequestID()
        pendingSearchRequestID = id
        pendingSearchQuery = query
        issuedSearchRequestIDs.insert(id)
        messageSearchState = .loading(query: query)
        client.submit(
            .searchMessages(
                requestID: id,
                accountID: identity.accountID,
                query: query,
                limit: Self.searchResultLimit
            )
        )
    }

    func clearMessageSearch() {
        pendingSearchRequestID = nil
        pendingSearchQuery = nil
        messageSearchState = .idle
    }

    func beginNewTopic(streamID: Int64, name: String) -> ConversationKey? {
        guard let identity,
              streamID > 0,
              let topic = Self.validatedTopicName(name)
        else {
            notice = "Enter a valid topic name."
            return nil
        }
        let key = ConversationKey.topic(
            accountID: identity.accountID,
            streamID: streamID,
            topic: topic
        )
        knownTopics[key] = LiveTopicSnapshot(
            streamID: streamID,
            name: topic,
            maxMessageID: knownTopics[key]?.maxMessageID ?? 0
        )
        rebuildPresentation()
        return key
    }

    @discardableResult
    func renameTopic(
        _ key: ConversationKey,
        anchorMessageID: Int64,
        newName: String
    ) -> Bool {
        guard case let .topic(accountID, streamID, oldTopic) = key,
              identity?.accountID == accountID,
              streamID > 0,
              anchorMessageID > 0,
              let topic = Self.validatedTopicName(newName),
              topic != oldTopic
        else {
            notice = "Choose a different valid topic name."
            return false
        }
        return submitTopicAction(
            .rename(key: key, messageID: anchorMessageID, newTopic: topic)
        )
    }

    @discardableResult
    func moveMessage(
        _ message: MessageViewData,
        to newName: String
    ) -> Bool {
        guard let identity,
              message.accountID == identity.accountID,
              message.id > 0,
              let streamID = message.sourceStreamID,
              let oldTopic = message.sourceTopic,
              let topic = Self.validatedTopicName(newName),
              topic != oldTopic
        else {
            notice = "Choose a different valid destination topic."
            return false
        }
        let key = ConversationKey.topic(
            accountID: identity.accountID,
            streamID: streamID,
            topic: oldTopic
        )
        return submitTopicAction(
            .move(key: key, messageID: message.id, newTopic: topic)
        )
    }

    func retryTopicAction() {
        guard case let .failed(action, _) = topicActionState else {
            return
        }
        _ = submitTopicAction(action)
    }

    func clearRequestedTopicNavigation() {
        requestedTopicNavigation = nil
    }

    func openSearchResult(_ result: MessageSearchResult) {
        guard identity?.accountID == result.accountID,
              result.conversationKey.accountID == result.accountID
        else {
            return
        }
        pendingSearchRequestID = nil
        pendingSearchQuery = nil
        messageSearchState = .idle
        stashVisiblePage()
        pendingOlderRequestID = nil
        isLoadingOlderMessages = false
        activeSelection = result.conversationKey
        conversationState = .loading(title: result.title, subtitle: result.subtitle)

        let id = nextRequestID()
        pendingFocusedMessageRequestID = id
        issuedFocusedMessageRequestIDs.insert(id)
        client.submit(
            .openMessage(
                requestID: id,
                key: result.conversationKey,
                messageID: result.messageID,
                numBefore: Self.searchContextRadius,
                numAfter: Self.searchContextRadius
            )
        )
    }

    func loadOlderMessages(for key: ConversationKey) {
        guard activeSelection == key,
              !isLoadingOlderMessages,
              case let .loaded(page) = conversationState,
              page.beforeCursor != nil,
              let beforeMessageID = page.messages.first?.id,
              beforeMessageID > 0
        else {
            return
        }
        let id = nextRequestID()
        pendingOlderRequestID = id
        isLoadingOlderMessages = true
        client.submit(
            .loadOlderMessages(
                requestID: id,
                key: key,
                beforeMessageID: beforeMessageID,
                limit: Self.conversationPageSize
            )
        )
    }

    @discardableResult
    func sendText(_ content: String, to key: ConversationKey) -> Bool {
        guard let identity, identity.accountID == key.accountID else {
            return false
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let id = nextRequestID()
        let localID = "swift-\(id)"
        let localMessageID = -Int64(id)
        let send = PendingSend(
            key: key,
            content: trimmed,
            localID: localID,
            localMessageID: localMessageID
        )
        sendsByRequestID[id] = send
        switch key {
        case let .topic(_, streamID, topic):
            client.submit(
                .sendChannelMessage(
                    requestID: id,
                    accountID: identity.accountID,
                    streamID: streamID,
                    topic: topic,
                    content: trimmed,
                    localID: localID
                )
            )
        case let .directMessage(_, recipientIDs):
            client.submit(
                .sendDirectMessage(
                    requestID: id,
                    accountID: identity.accountID,
                    recipientIDs: recipientIDs,
                    content: trimmed,
                    localID: localID
                )
            )
        default:
            sendsByRequestID.removeValue(forKey: id)
            notice = "Choose a topic or direct message before sending."
            return false
        }
        appendLocalEcho(send, id: localMessageID)
        return true
    }

    @discardableResult
    func editMessage(_ message: MessageViewData, content: String) -> Bool {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            notice = "A message cannot be empty."
            return false
        }
        return submitMessageAction(.edit(messageID: message.id, content: content))
    }

    @discardableResult
    func deleteMessage(_ message: MessageViewData) -> Bool {
        submitMessageAction(.delete(messageID: message.id))
    }

    @discardableResult
    func toggleThumbsUp(_ message: MessageViewData) -> Bool {
        submitMessageAction(
            .reaction(messageID: message.id, add: !message.hasOwnThumbsUp)
        )
    }

    @discardableResult
    func toggleStar(_ message: MessageViewData) -> Bool {
        submitMessageAction(
            .flag(messageID: message.id, flag: .starred, add: !message.isStarred)
        )
    }

    @discardableResult
    func setRead(_ message: MessageViewData, read: Bool) -> Bool {
        submitMessageAction(
            .flag(messageID: message.id, flag: .read, add: read)
        )
    }

    /// Puts a quote of `message` into the open conversation's composer.
    func quote(_ message: MessageViewData) {
        guard let activeSelection else {
            return
        }
        requestMessageSource(for: message, purpose: .quote(into: activeSelection))
    }

    /// Posts a quote of `message` into another conversation.
    func forward(_ message: MessageViewData, to key: ConversationKey) {
        requestMessageSource(for: message, purpose: .forward(to: key))
    }

    /// Topics and direct messages a message can be forwarded to.
    func forwardDestinations(matching query: String) -> [NavigationDestination] {
        navigationDirectory
            .search(query, limit: 400)
            .filter {
                switch $0.key {
                case .topic, .directMessage: true
                default: false
                }
            }
            .prefix(30)
            .map { $0 }
    }

    private func requestMessageSource(
        for message: MessageViewData,
        purpose: PendingMessageSource.Purpose
    ) {
        guard let identity, message.id > 0, message.accountID == identity.accountID else {
            notice = "This message is not available to quote."
            return
        }
        let id = nextRequestID()
        messageSourceRequests[id] = PendingMessageSource(purpose: purpose, message: message)
        notice = nil
        client.submit(
            .fetchMessageSource(
                requestID: id,
                accountID: identity.accountID,
                messageID: message.id
            )
        )
    }

    private func messageSourceMarkdown(_ pending: PendingMessageSource, source: String) -> String {
        let message = pending.message
        let streamID: Int64?
        let topic: String?
        var recipientIDs: [Int64] = []
        switch message.conversationKey {
        case let .topic(_, keyStreamID, keyTopic):
            streamID = message.sourceStreamID ?? keyStreamID
            topic = message.sourceTopic ?? keyTopic
        case let .directMessage(_, ids):
            streamID = nil
            topic = nil
            recipientIDs = ids
        default:
            streamID = message.sourceStreamID
            topic = message.sourceTopic
        }
        let streamName = streamID.flatMap {
            navigationDirectory.destination(
                for: .channel(accountID: message.accountID, streamID: $0)
            )?.title
        }
        let link = identity.flatMap {
            MessageQuote.permalink(
                serverURL: $0.serverURL,
                streamID: streamID,
                streamName: streamName,
                topic: topic,
                recipientIDs: recipientIDs,
                messageID: message.id
            )
        }
        return MessageQuote.markdown(
            senderName: message.senderName,
            senderID: message.senderID,
            permalink: link,
            source: source
        )
    }

    func retryMessageAction(for messageID: Int64) {
        guard let action = failedMessageActions[messageID] else {
            return
        }
        _ = submitMessageAction(action)
    }

    func retrySend(_ message: MessageViewData) {
        guard let send = failedSends.removeValue(forKey: message.id) else {
            return
        }
        modifyLoadedMessage(message.id) { value in
            value.deliveryState = .pending
        }
        let id = nextRequestID()
        sendsByRequestID[id] = send
        switch send.key {
        case let .topic(_, streamID, topic):
            client.submit(
                .sendChannelMessage(
                    requestID: id,
                    accountID: send.key.accountID,
                    streamID: streamID,
                    topic: topic,
                    content: send.content,
                    localID: send.localID
                )
            )
        case let .directMessage(_, recipientIDs):
            client.submit(
                .sendDirectMessage(
                    requestID: id,
                    accountID: send.key.accountID,
                    recipientIDs: recipientIDs,
                    content: send.content,
                    localID: send.localID
                )
            )
        default:
            sendsByRequestID.removeValue(forKey: id)
        }
    }

    func uploadAttachment(_ fileURL: URL, to key: ConversationKey) {
        guard let identity,
              identity.accountID == key.accountID,
              activeSelection == key,
              fileURL.isFileURL,
              !attachmentUploadState.isUploading
        else {
            notice = "Connect to a conversation before adding an attachment."
            return
        }
        let filename = fileURL.lastPathComponent
        guard !filename.isEmpty else {
            attachmentUploadState = .failed(
                filename: "Attachment",
                message: "The selected file has no usable name."
            )
            return
        }

        let accessedSecurityScope = fileURL.startAccessingSecurityScopedResource()
        let pending = PendingAttachmentUpload(
            key: key,
            fileURL: fileURL,
            filename: filename,
            accessedSecurityScope: accessedSecurityScope
        )
        let id = nextRequestID()
        attachmentUploadsByRequestID[id] = pending
        failedAttachmentUpload = nil
        attachmentUploadState = .uploading(filename: filename)
        client.submit(
            .uploadAttachment(
                requestID: id,
                accountID: identity.accountID,
                localPath: fileURL.path,
                filename: filename
            )
        )
    }

    func retryAttachmentUpload() {
        guard let failedAttachmentUpload else { return }
        uploadAttachment(failedAttachmentUpload.fileURL, to: failedAttachmentUpload.key)
    }

    func consumeAttachmentInsertion(id: UInt64) {
        guard attachmentInsertion?.id == id else { return }
        attachmentInsertion = nil
    }

    func loadMedia(_ remoteURL: String) {
        guard let identity,
              !remoteURL.isEmpty,
              mediaLocalURLs[remoteURL] == nil,
              !pendingMediaURLs.contains(remoteURL)
        else { return }
        let id = nextRequestID()
        pendingMediaURLs.insert(remoteURL)
        mediaRequestsByRequestID[id] = remoteURL
        mediaFailures.removeValue(forKey: remoteURL)
        client.submit(
            .loadMedia(
                requestID: id,
                accountID: identity.accountID,
                remoteURL: remoteURL
            )
        )
    }

    func retryMedia(_ remoteURL: String) {
        mediaFailures.removeValue(forKey: remoteURL)
        loadMedia(remoteURL)
    }

    func disconnect() {
        client.submit(.disconnect(requestID: nextRequestID()))
    }

    private func consume(_ event: BridgeEvent) async {
        switch event {
        case let .cachedSessionLoaded(_, identity, snapshot):
            // A live session that won the race must not be replaced by older data.
            guard self.identity == nil else {
                return
            }
            cachedSessionRequestID = nil
            self.identity = identity
            serverURL = identity.serverURL
            email = identity.email
            apply(snapshot)
            notificationPlanner.prime(with: snapshot)
            loadDrafts(for: identity.accountID)
            let inbox = ConversationKey.inbox(accountID: identity.accountID)
            openConversation(inbox)

        case let .sessionStarted(_, identity, credential, snapshot):
            cancelReconnect()
            hasLiveSession = true
            self.identity = identity
            serverURL = identity.serverURL
            email = identity.email
            rememberLastAccount(identity)
            apply(snapshot)
            notificationPlanner.prime(with: snapshot)
            notifier?.requestAuthorization()
            loadDrafts(for: identity.accountID)
            startPresenceUpdates(accountID: identity.accountID)
            do {
                try await credentialStore.save(credential)
            } catch {
                notice = "Connected, but the API key could not be saved in Keychain."
            }
            connectionState = .connected
            if let activeSelection, activeSelection.accountID == identity.accountID {
                // Keep the user's place when a cached session went live.
                refreshConversation(activeSelection)
            } else {
                openConversation(ConversationKey.inbox(accountID: identity.accountID))
            }

        case let .snapshotUpdated(accountID, snapshot):
            guard identity?.accountID == accountID else {
                return
            }
            let shouldRefresh = activeSelection.map {
                conversationAffected(by: snapshot, key: $0)
            } ?? false
            apply(snapshot)
            notifyAboutNewMessages(in: snapshot)
            connectionState = .connected
            if shouldRefresh, let activeSelection {
                refreshConversation(activeSelection)
            }

        case let .conversationOpened(_, page):
            guard pendingFocusedMessageRequestID == nil,
                  activeSelection == page.key
            else {
                return
            }
            rememberTopics(from: page.messages)
            let existing = cachedPlaceholderKey == page.key ? nil : loadedPage(for: page.key)
            cachedPlaceholderKey = nil
            let conversationPage = makeConversationPage(page, merging: existing)
            if isServingCachedData {
                // Cached copy: readable, but writes wait for a live connection.
                conversationState = .offline(conversationPage)
                return
            }
            conversationState = .loaded(conversationPage)
            let messageIDs = page.messages.map(\.messageID)
            if !messageIDs.isEmpty, let identity {
                client.submit(
                    .markRead(
                        requestID: nextRequestID(),
                        accountID: identity.accountID,
                        messageIDs: messageIDs
                    )
                )
            }

        case let .cachedConversationLoaded(_, page):
            // Only a conversation still waiting for its first page uses the cache; the
            // fresh page replaces it and is the one that marks messages read.
            guard pendingFocusedMessageRequestID == nil,
                  activeSelection == page.key,
                  case .loading = conversationState
            else {
                return
            }
            rememberTopics(from: page.messages)
            let cachedPage = makeConversationPage(page)
            cachedPlaceholderKey = page.key
            conversationState = isServingCachedData ? .offline(cachedPage) : .loaded(cachedPage)

        case let .conversationHistoryLoaded(requestID, page):
            guard pendingOlderRequestID == requestID else {
                return
            }
            pendingOlderRequestID = nil
            isLoadingOlderMessages = false
            guard activeSelection == page.key,
                  let existing = loadedPage(for: page.key)
            else {
                return
            }
            rememberTopics(from: page.messages)
            conversationState = .loaded(
                makeHistoricalConversationPage(page, merging: existing)
            )

        case let .searchCompleted(requestID, accountID, results):
            issuedSearchRequestIDs.remove(requestID)
            guard pendingSearchRequestID == requestID,
                  identity?.accountID == accountID,
                  let query = pendingSearchQuery
            else {
                return
            }
            pendingSearchRequestID = nil
            pendingSearchQuery = nil
            rememberTopics(from: results.map(\.message))
            var seen = Set<MessageSearchResult.ID>()
            let mapped = results
                .compactMap(makeSearchResult)
                .filter { seen.insert($0.id).inserted }
            messageSearchState = .loaded(query: query, results: mapped)

        case let .messageFocused(requestID, messageID, page):
            issuedFocusedMessageRequestIDs.remove(requestID)
            guard pendingFocusedMessageRequestID == requestID,
                  activeSelection == page.key,
                  page.messages.contains(where: { $0.messageID == messageID })
            else {
                return
            }
            pendingFocusedMessageRequestID = nil
            rememberTopics(from: page.messages)
            conversationState = .loaded(
                makeConversationPage(page, focusedMessageID: messageID)
            )
            let messageIDs = page.messages.map(\.messageID)
            if !messageIDs.isEmpty, let identity {
                client.submit(
                    .markRead(
                        requestID: nextRequestID(),
                        accountID: identity.accountID,
                        messageIDs: messageIDs
                    )
                )
            }

        case let .messageSent(requestID, _, messageID):
            if let send = sendsByRequestID.removeValue(forKey: requestID) {
                keepEchoUntilServerCopyArrives(send, serverMessageID: messageID)
            }
            if let activeSelection {
                refreshConversation(activeSelection)
            }

        case let .attachmentUploaded(requestID, attachment):
            guard let pending = attachmentUploadsByRequestID.removeValue(forKey: requestID) else {
                return
            }
            stopSecurityScope(for: pending)
            guard identity?.accountID == attachment.accountID else { return }
            attachmentUploadState = .idle
            failedAttachmentUpload = nil
            attachmentInsertion = ComposerAttachmentInsertion(
                id: requestID,
                key: pending.key,
                filename: attachment.filename,
                markdown: attachment.markdown
            )

        case let .mediaReady(requestID, media):
            guard let requestedURL = mediaRequestsByRequestID.removeValue(forKey: requestID) else {
                return
            }
            pendingMediaURLs.remove(requestedURL)
            guard identity?.accountID == media.accountID else { return }
            mediaLocalURLs[requestedURL] = media.localURL
            mediaLocalURLs[media.remoteURL] = media.localURL
            mediaFailures.removeValue(forKey: requestedURL)

        case let .messageEdited(requestID, messageID, _):
            completeMessageAction(requestID: requestID, messageID: messageID)
            if let activeSelection {
                refreshConversation(activeSelection)
            }

        case let .messageDeleted(requestID, messageID):
            guard messageActionsByRequestID.removeValue(forKey: requestID) != nil else {
                return
            }
            failedMessageActions.removeValue(forKey: messageID)
            removeLoadedMessage(messageID)

        case let .reactionUpdated(requestID, messageID, _, _):
            completeMessageAction(requestID: requestID, messageID: messageID)
            if let activeSelection {
                refreshConversation(activeSelection)
            }

        case let .messageFlagUpdated(requestID, messageIDs, _, _):
            guard let messageID = messageIDs.first else {
                return
            }
            completeMessageAction(requestID: requestID, messageID: messageID)
            if let activeSelection {
                refreshConversation(activeSelection)
            }

        case let .topicUpdated(requestID, update):
            guard let action = topicActionsByRequestID.removeValue(forKey: requestID),
                  identity?.accountID == update.accountID
            else {
                return
            }
            topicActionState = .idle
            applyTopicUpdate(update, action: action)

        case let .messageSourceLoaded(requestID, _, source):
            guard let pending = messageSourceRequests.removeValue(forKey: requestID),
                  identity?.accountID == pending.message.accountID
            else {
                return
            }
            let markdown = messageSourceMarkdown(pending, source: source)
            switch pending.purpose {
            case let .quote(key):
                attachmentInsertion = ComposerAttachmentInsertion(
                    id: requestID,
                    key: key,
                    filename: "quote",
                    markdown: markdown + "\n\n",
                    quote: ComposerQuote(
                        senderName: pending.message.senderName,
                        snippet: ComposerQuote.snippet(from: pending.message.plainText),
                        markdown: markdown
                    )
                )
            case let .forward(key):
                if sendText(markdown, to: key) {
                    let name = navigationDirectory.destination(for: key)?.title ?? "the conversation"
                    notice = "Forwarded to \(name)."
                }
            }

        case .messagesMarkedRead, .pong:
            break

        case let .retryScheduled(_, delayMilliseconds):
            sessionLog.info("sync retry scheduled in \(delayMilliseconds, privacy: .public) ms")
            connectionState = .retrying(delayMilliseconds: delayMilliseconds)

        case let .draftsLoaded(_, accountID, loaded):
            guard identity?.accountID == accountID else {
                return
            }
            // Text typed since launch wins over what was stored.
            for draft in loaded where drafts[draft.key] == nil {
                drafts[draft.key] = draft.content
            }

        case let .presenceUpdated(accountID, presences):
            guard identity?.accountID == accountID else {
                return
            }
            applyPresence(presences)

        case let .syncResumed(accountID):
            if identity?.accountID == accountID, case .retrying = connectionState {
                sessionLog.info("sync resumed")
                connectionState = .connected
            }

        case .disconnected:
            cancelReconnect()
            forgetLastAccount()
            resetSessionState()
            connectionState = .signedOut

        case let .failed(requestID, message):
            if let requestID, requestID == cachedSessionRequestID {
                // No cached data yet (first run); the live connection continues.
                cachedSessionRequestID = nil
            } else if let requestID,
               let pending = attachmentUploadsByRequestID.removeValue(forKey: requestID)
            {
                stopSecurityScope(for: pending)
                failedAttachmentUpload = pending.withoutSecurityScope()
                attachmentUploadState = .failed(filename: pending.filename, message: message)
                notice = "Attachment upload failed. You can retry it."
            } else if let requestID,
                      let remoteURL = mediaRequestsByRequestID.removeValue(forKey: requestID)
            {
                pendingMediaURLs.remove(remoteURL)
                mediaFailures[remoteURL] = message
            } else if let requestID, issuedSearchRequestIDs.remove(requestID) != nil {
                guard pendingSearchRequestID == requestID else {
                    return
                }
                let query = pendingSearchQuery ?? ""
                pendingSearchRequestID = nil
                pendingSearchQuery = nil
                messageSearchState = .failed(query: query, message: message)
            } else if let requestID,
                      issuedFocusedMessageRequestIDs.remove(requestID) != nil
            {
                guard pendingFocusedMessageRequestID == requestID else {
                    return
                }
                pendingFocusedMessageRequestID = nil
                conversationState = .failure(
                    title: "Message unavailable",
                    subtitle: organizationName,
                    message: message
                )
            } else if let requestID, pendingOlderRequestID == requestID {
                pendingOlderRequestID = nil
                isLoadingOlderMessages = false
                notice = "Earlier messages could not be loaded: \(message)"
            } else if let requestID,
                      let action = topicActionsByRequestID.removeValue(forKey: requestID)
            {
                topicActionState = .failed(action: action, message: message)
                notice = "Topic update failed: \(message)"
            } else if let requestID,
                      let submitted = messageActionsByRequestID.removeValue(forKey: requestID)
            {
                failedMessageActions[submitted.action.messageID] = submitted.action
                restoreMessageAfterFailure(submitted, message: message)
                notice = "Message action failed: \(message)"
            } else if let requestID,
                      let send = sendsByRequestID.removeValue(forKey: requestID)
            {
                failedSends[send.localMessageID] = send
                modifyLoadedMessage(send.localMessageID) { value in
                    value.deliveryState = .failed
                }
                notice = "Message could not be sent. You can retry it."
            } else if let requestID,
                      messageSourceRequests.removeValue(forKey: requestID) != nil
            {
                notice = "The original message could not be loaded: \(message)"
            } else if requestID != nil,
                      identity != nil,
                      connectionState != .connected,
                      message == "no matching live account session"
            {
                // Cached session without a live connection and nothing cached
                // for this conversation.
                conversationState = .failure(
                    title: "Not available offline",
                    subtitle: organizationName,
                    message: "This conversation has not been cached yet. It will load once you are back online."
                )
            } else if requestID != nil,
                      identity != nil,
                      connectionState == .connecting,
                      Self.isTransientFailure(message)
            {
                // Offline with a cached session on screen: keep reading and retry.
                scheduleReconnect()
            } else if requestID == nil, identity != nil {
                // The Rust core ended the live session (for example after the
                // server rejected the stored key). Return to the login surface
                // with the reason instead of leaving a window that never updates.
                // Only a credential rejection ends a session, so the saved key is
                // known to be unusable and must not be offered again.
                let rejectedAccountID = identity?.accountID
                sessionLog.error("session ended by the core; discarding saved key: \(message)")
                cancelReconnect()
                resetSessionState()
                if let rejectedAccountID {
                    try? await credentialStore.delete(accountID: rejectedAccountID)
                }
                forgetLastAccount()
                connectionState = .failed(message: message)
            } else {
                connectionState = .failed(message: message)
            }
        }
    }

    private func resetSessionState() {
        hasLiveSession = false
        snapshotMessages = [:]
        avatarURLs = [:]
        presenceTask?.cancel()
        presenceTask = nil
        presenceStates = [:]
        cachedPlaceholderKey = nil
        recentPages = [:]
        recentPageOrder = []
        notificationPlanner.reset()
        unseenNotificationCount = 0
        notifier?.setBadge(0)
        draftSaveTasks.values.forEach { $0.cancel() }
        draftSaveTasks = [:]
        drafts = [:]
        attachmentUploadsByRequestID.values.forEach(stopSecurityScope)
        identity = nil
        sidebarSnapshot = nil
        navigationDirectory = NavigationDirectory(destinations: [])
        activeSelection = nil
        pendingOlderRequestID = nil
        pendingSearchRequestID = nil
        pendingSearchQuery = nil
        issuedSearchRequestIDs = []
        pendingFocusedMessageRequestID = nil
        issuedFocusedMessageRequestIDs = []
        topicActionsByRequestID = [:]
        messageActionsByRequestID = [:]
        failedMessageActions = [:]
        sendsByRequestID = [:]
        failedSends = [:]
        confirmedEchoes = [:]
        attachmentUploadsByRequestID = [:]
        failedAttachmentUpload = nil
        attachmentUploadState = .idle
        attachmentInsertion = nil
        mediaRequestsByRequestID = [:]
        pendingMediaURLs = []
        mediaLocalURLs = [:]
        mediaFailures = [:]
        messageSourceRequests = [:]
        isLoadingOlderMessages = false
        messageSearchState = .idle
        topicActionState = .idle
        requestedTopicNavigation = nil
        knownTopics = [:]
    }

    private func stopSecurityScope(for pending: PendingAttachmentUpload) {
        if pending.accessedSecurityScope {
            pending.fileURL.stopAccessingSecurityScopedResource()
        }
    }

    /// Whether a snapshot removed, added, or changed a message that the open
    /// conversation shows. Unrelated snapshots (other channels, user or
    /// subscription changes) no longer trigger a network refetch.
    private func conversationAffected(by snapshot: LiveSnapshot, key: ConversationKey) -> Bool {
        guard let identity else {
            return false
        }
        let incoming = Dictionary(
            snapshot.messages.map { ($0.messageID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        if snapshotMessages.keys.contains(where: { incoming[$0] == nil }) {
            return true
        }
        return incoming.values.contains { message in
            snapshotMessages[message.messageID] != message
                && Self.message(message, belongsTo: key, identity: identity)
        }
    }

    private static func message(
        _ message: LiveMessageSnapshot,
        belongsTo key: ConversationKey,
        identity: LiveSessionIdentity
    ) -> Bool {
        switch key {
        case .inbox, .unread, .drafts:
            true
        case .mentions:
            NotificationPlanner.isMention(message)
        case .starred:
            message.flags.contains("starred")
        case let .channel(_, streamID):
            message.streamID == streamID
        case .topic, .directMessage:
            NotificationPlanner.conversationKey(for: message, identity: identity) == key
        }
    }

    /// Reports our own presence and refreshes everyone else's once a minute.
    private func startPresenceUpdates(accountID: String) {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            // Let the session settle before the first request.
            try? await Task.sleep(for: .seconds(1.5))
            while !Task.isCancelled {
                guard self?.submitPresenceRefresh(accountID: accountID) != nil else {
                    return
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func submitPresenceRefresh(accountID: String) {
        client.submit(
            .refreshPresence(
                requestID: nextRequestID(),
                accountID: accountID,
                isActive: isApplicationActive()
            )
        )
    }

    private func applyPresence(_ presences: [LivePresence]) {
        presenceStates = Dictionary(
            presences.map { ($0.userID, $0.state) },
            uniquingKeysWith: { _, latest in latest }
        )
        guard let sidebar = sidebarSnapshot else {
            return
        }
        let directMessages = sidebar.directMessages.map { directMessage in
            DirectMessageSnapshot(
                userID: directMessage.userID,
                displayName: directMessage.displayName,
                initials: directMessage.initials,
                unreadCount: directMessage.unreadCount,
                presence: presenceStates[directMessage.userID] ?? .offline,
                avatarURL: directMessage.avatarURL
            )
        }
        guard directMessages != sidebar.directMessages else {
            return
        }
        sidebarSnapshot = SidebarSnapshot(
            accountID: sidebar.accountID,
            organizationName: sidebar.organizationName,
            organizationHost: sidebar.organizationHost,
            quickLinks: sidebar.quickLinks,
            channels: sidebar.channels,
            directMessages: directMessages,
            currentUserName: sidebar.currentUserName,
            currentUserInitials: sidebar.currentUserInitials,
            organizationIconURL: sidebar.organizationIconURL,
            currentUserAvatarURL: sidebar.currentUserAvatarURL
        )
    }

    private func apply(_ snapshot: LiveSnapshot) {
        guard let identity else {
            return
        }
        snapshotMessages = Dictionary(
            snapshot.messages.map { ($0.messageID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        avatarURLs = Dictionary(
            snapshot.users.compactMap { user in
                user.avatarURL.map { (user.userID, $0) }
            },
            uniquingKeysWith: { _, latest in latest }
        )
        rememberTopics(from: snapshot.topics)
        rememberTopics(from: snapshot.messages)
        sidebarSnapshot = Self.makeSidebar(
            snapshot: snapshot,
            identity: identity,
            topics: Array(knownTopics.values),
            presence: presenceStates
        )
        rebuildPresentation()
    }

    private func makeConversationPage(
        _ livePage: LiveConversationPage,
        merging existing: ConversationPage? = nil,
        focusedMessageID: Int64? = nil
    ) -> ConversationPage {
        let destination = navigationDirectory.destination(for: livePage.key)
        let incoming = makeMessages(livePage)
        let messages = removeConfirmedEchoes(
            from: mergeMessages(existing?.messages ?? [], incoming)
        )
        let hadReachedOldest = existing?.beforeCursor == nil && existing != nil
        return ConversationPage(
            key: livePage.key,
            title: destination?.title ?? "Conversation",
            subtitle: destination?.subtitle ?? organizationName,
            messages: messages,
            beforeCursor: livePage.foundOldest || hadReachedOldest
                ? nil
                : messages.first.map { String($0.id) },
            afterCursor: livePage.foundNewest
                ? nil
                : messages.last.map { String($0.id) },
            focusedMessageID: focusedMessageID ?? existing?.focusedMessageID
        )
    }

    private func makeHistoricalConversationPage(
        _ livePage: LiveConversationPage,
        merging existing: ConversationPage
    ) -> ConversationPage {
        let messages = mergeMessages(makeMessages(livePage), existing.messages)
        return ConversationPage(
            key: existing.key,
            title: existing.title,
            subtitle: existing.subtitle,
            messages: messages,
            beforeCursor: livePage.foundOldest
                ? nil
                : messages.first.map { String($0.id) },
            afterCursor: existing.afterCursor,
            focusedMessageID: existing.focusedMessageID
        )
    }

    private func makeMessages(_ livePage: LiveConversationPage) -> [MessageViewData] {
        livePage.messages.map { message in
            let thumbsUp = message.reactions.filter { $0.emojiName == "thumbs_up" }
            return MessageViewData(
                id: message.messageID,
                accountID: livePage.key.accountID,
                conversationKey: livePage.key,
                senderID: message.senderID,
                senderName: message.senderFullName,
                senderInitials: Self.initials(for: message.senderFullName),
                timestamp: message.timestamp,
                content: message.content,
                isOwnMessage: message.senderID == identity?.userID,
                sourceStreamID: message.streamID,
                sourceTopic: message.topic,
                isStarred: message.flags.contains("starred"),
                reactionCount: thumbsUp.count,
                hasOwnThumbsUp: thumbsUp.contains { $0.userID == identity?.userID },
                isRead: message.flags.contains("read"),
                senderAvatarURL: avatarURLs[message.senderID]
            )
        }
    }

    private func submitMessageAction(_ action: MessageAction) -> Bool {
        guard let identity,
              let activeSelection,
              action.messageID > 0,
              let message = loadedPage(for: activeSelection)?
                .messages.first(where: { $0.id == action.messageID }),
              message.accountID == identity.accountID
        else {
            notice = "This message is not available for an action."
            return false
        }
        if case .pending = message.actionState {
            return false
        }

        let id = nextRequestID()
        messageActionsByRequestID[id] = SubmittedMessageAction(
            action: action,
            priorMessage: message
        )
        failedMessageActions.removeValue(forKey: action.messageID)
        applyOptimistic(action)
        notice = nil

        switch action {
        case let .edit(messageID, content):
            client.submit(
                .editMessage(
                    requestID: id,
                    accountID: identity.accountID,
                    messageID: messageID,
                    content: content
                )
            )
        case let .delete(messageID):
            client.submit(
                .deleteMessage(
                    requestID: id,
                    accountID: identity.accountID,
                    messageID: messageID
                )
            )
        case let .reaction(messageID, add):
            client.submit(
                .updateReaction(
                    requestID: id,
                    accountID: identity.accountID,
                    messageID: messageID,
                    emojiName: "thumbs_up",
                    add: add
                )
            )
        case let .flag(messageID, flag, add):
            client.submit(
                .updateMessageFlag(
                    requestID: id,
                    accountID: identity.accountID,
                    messageIDs: [messageID],
                    flag: flag,
                    add: add
                )
            )
        }
        return true
    }

    private func applyOptimistic(_ action: MessageAction) {
        modifyLoadedMessage(action.messageID) { message in
            message.actionState = .pending(action.kind)
            switch action {
            case let .edit(_, content):
                message.content = [.paragraph([.text(content)])]
            case .delete:
                break
            case let .reaction(_, add):
                message.hasOwnThumbsUp = add
                message.reactionCount = max(0, message.reactionCount + (add ? 1 : -1))
            case let .flag(_, flag, add):
                if flag == .starred {
                    message.isStarred = add
                } else {
                    message.isRead = add
                }
            }
        }
    }

    private func completeMessageAction(requestID: UInt64, messageID: Int64) {
        guard messageActionsByRequestID.removeValue(forKey: requestID) != nil else {
            return
        }
        failedMessageActions.removeValue(forKey: messageID)
        modifyLoadedMessage(messageID) { message in
            message.actionState = .idle
        }
    }

    private func restoreMessageAfterFailure(
        _ submitted: SubmittedMessageAction,
        message failureMessage: String
    ) {
        var restored = submitted.priorMessage
        restored.actionState = .failed(submitted.action.kind, message: failureMessage)
        replaceLoadedMessage(restored)
    }

    private func keepEchoUntilServerCopyArrives(_ send: PendingSend, serverMessageID: Int64) {
        if loadedPage(for: send.key)?.messages.contains(where: { $0.id == serverMessageID }) == true {
            removeLoadedMessage(send.localMessageID)
            return
        }
        confirmedEchoes[serverMessageID] = send.localMessageID
        modifyLoadedMessage(send.localMessageID) { message in
            message.deliveryState = .sent
        }
        // Never leave a duplicate behind if the refresh does not include the message.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.confirmedEchoes.removeValue(forKey: serverMessageID) != nil else {
                return
            }
            self.removeLoadedMessage(send.localMessageID)
        }
    }

    private func removeConfirmedEchoes(from messages: [MessageViewData]) -> [MessageViewData] {
        guard !confirmedEchoes.isEmpty else {
            return messages
        }
        let present = Set(messages.map(\.id))
        let resolved = confirmedEchoes.filter { present.contains($0.key) }
        guard !resolved.isEmpty else {
            return messages
        }
        resolved.keys.forEach { confirmedEchoes.removeValue(forKey: $0) }
        let localIDs = Set(resolved.values)
        return messages.filter { !localIDs.contains($0.id) }
    }

    private func appendLocalEcho(_ send: PendingSend, id: Int64) {
        guard let identity,
              case let .loaded(page) = conversationState,
              page.key == send.key
        else {
            return
        }
        let source: (Int64?, String?)
        if case let .topic(_, streamID, topic) = send.key {
            source = (streamID, topic)
        } else {
            source = (nil, nil)
        }
        let echo = MessageViewData(
            id: id,
            accountID: identity.accountID,
            conversationKey: send.key,
            senderID: identity.userID,
            senderName: identity.fullName,
            senderInitials: Self.initials(for: identity.fullName),
            timestamp: .now,
            content: [.paragraph([.text(send.content)])],
            isOwnMessage: true,
            sourceStreamID: source.0,
            sourceTopic: source.1,
            deliveryState: .pending,
            senderAvatarURL: avatarURLs[identity.userID]
        )
        replaceConversationMessages(page.messages + [echo], in: page)
    }

    private func modifyLoadedMessage(
        _ messageID: Int64,
        mutation: (inout MessageViewData) -> Void
    ) {
        guard case let .loaded(page) = conversationState,
              let index = page.messages.firstIndex(where: { $0.id == messageID })
        else {
            return
        }
        var messages = page.messages
        mutation(&messages[index])
        replaceConversationMessages(messages, in: page)
    }

    private func replaceLoadedMessage(_ replacement: MessageViewData) {
        modifyLoadedMessage(replacement.id) { message in
            message = replacement
        }
    }

    private func removeLoadedMessage(_ messageID: Int64) {
        guard case let .loaded(page) = conversationState else {
            return
        }
        replaceConversationMessages(
            page.messages.filter { $0.id != messageID },
            in: page
        )
    }

    private func replaceConversationMessages(
        _ messages: [MessageViewData],
        in page: ConversationPage
    ) {
        conversationState = .loaded(
            ConversationPage(
                key: page.key,
                title: page.title,
                subtitle: page.subtitle,
                messages: messages.sorted { left, right in
                    if left.id > 0, right.id > 0 {
                        return left.id < right.id
                    }
                    if left.id > 0 {
                        return true
                    }
                    if right.id > 0 {
                        return false
                    }
                    return left.id > right.id
                },
                beforeCursor: page.beforeCursor,
                afterCursor: page.afterCursor,
                focusedMessageID: page.focusedMessageID
            )
        )
    }

    private func makeSearchResult(_ result: LiveSearchResult) -> MessageSearchResult? {
        guard let identity,
              result.key.accountID == identity.accountID,
              result.message.messageID > 0
        else {
            return nil
        }

        let title: String
        let subtitle: String
        let systemImage: String
        switch result.key {
        case let .topic(_, streamID, topic):
            let channel = sidebarSnapshot?.channels
                .first(where: { $0.streamID == streamID })?.name ?? "channel"
            title = topic.isEmpty ? "(no topic)" : topic
            subtitle = "#\(channel)"
            systemImage = "text.bubble"
        case let .channel(_, streamID):
            title = sidebarSnapshot?.channels
                .first(where: { $0.streamID == streamID })?.name ?? "Channel"
            subtitle = "Channel"
            systemImage = "number"
        case let .directMessage(_, recipientIDs):
            let names = recipientIDs.compactMap { userID in
                sidebarSnapshot?.directMessages
                    .first(where: { $0.userID == userID })?.displayName
            }
            title = names.isEmpty ? "Direct message" : names.joined(separator: ", ")
            subtitle = "Direct message"
            systemImage = "person.crop.circle"
        default:
            let destination = navigationDirectory.destination(for: result.key)
            title = destination?.title ?? "Conversation"
            subtitle = destination?.subtitle ?? organizationName
            systemImage = destination?.systemImage ?? "text.bubble"
        }

        return MessageSearchResult(
            accountID: identity.accountID,
            conversationKey: result.key,
            messageID: result.message.messageID,
            senderName: result.message.senderFullName,
            timestamp: result.message.timestamp,
            contentPreview: result.message.content
                .map(\.plainText)
                .joined(separator: "\n"),
            title: title,
            subtitle: subtitle,
            systemImage: systemImage
        )
    }

    private func mergeMessages(
        _ first: [MessageViewData],
        _ second: [MessageViewData]
    ) -> [MessageViewData] {
        var messagesByID = Dictionary(
            uniqueKeysWithValues: first.map { ($0.id, $0) }
        )
        for message in second {
            if let existing = messagesByID[message.id],
               existing.deliveryState != .sent || existing.actionState != .idle
            {
                continue
            }
            messagesByID[message.id] = message
        }
        return messagesByID.values.sorted { left, right in
            if left.id > 0, right.id > 0 {
                return left.id < right.id
            }
            if left.id > 0 {
                return true
            }
            if right.id > 0 {
                return false
            }
            return left.id > right.id
        }
    }

    /// Remembers the page on screen (without unsent echoes or a search focus) so it
    /// can be shown immediately the next time that conversation opens.
    private func stashVisiblePage() {
        let page: ConversationPage
        switch conversationState {
        case let .loaded(visible), let .offline(visible):
            page = visible
        default:
            return
        }
        guard page.focusedMessageID == nil else {
            return
        }
        let confirmed = page.messages.filter { $0.id > 0 }
        guard !confirmed.isEmpty else {
            return
        }
        recentPages[page.key] = ConversationPage(
            key: page.key,
            title: page.title,
            subtitle: page.subtitle,
            messages: confirmed,
            beforeCursor: page.beforeCursor,
            afterCursor: page.afterCursor
        )
        recentPageOrder.removeAll { $0 == page.key }
        recentPageOrder.append(page.key)
        while recentPageOrder.count > Self.recentPageLimit {
            recentPages[recentPageOrder.removeFirst()] = nil
        }
    }

    private func loadedPage(for key: ConversationKey) -> ConversationPage? {
        guard case let .loaded(page) = conversationState, page.key == key else {
            return nil
        }
        return page
    }

    private func refreshConversation(_ key: ConversationKey) {
        guard identity?.accountID == key.accountID else {
            return
        }
        client.submit(
            .openConversation(
                requestID: nextRequestID(),
                key: key,
                limit: Self.conversationPageSize
            )
        )
    }

    private func rememberTopics(from topics: [LiveTopicSnapshot]) {
        guard let identity else {
            return
        }
        for topic in topics {
            let key = ConversationKey.topic(
                accountID: identity.accountID,
                streamID: topic.streamID,
                topic: topic.name
            )
            if knownTopics[key]?.maxMessageID ?? 0 < topic.maxMessageID {
                knownTopics[key] = topic
            }
        }
    }

    private func rememberTopics(from messages: [LiveMessageSnapshot]) {
        let topics = messages.compactMap { message -> LiveTopicSnapshot? in
            guard let streamID = message.streamID,
                  let topic = message.topic
            else {
                return nil
            }
            return LiveTopicSnapshot(
                streamID: streamID,
                name: topic,
                maxMessageID: message.messageID
            )
        }
        rememberTopics(from: topics)
        rebuildPresentation()
    }

    private func submitTopicAction(_ action: TopicAction) -> Bool {
        guard identity != nil else {
            return false
        }
        let id = nextRequestID()
        topicActionsByRequestID[id] = action
        topicActionState = .working(action)
        notice = nil
        switch action {
        case let .rename(key, messageID, newTopic):
            client.submit(
                .renameTopic(
                    requestID: id,
                    key: key,
                    messageID: messageID,
                    newTopic: newTopic
                )
            )
        case let .move(key, messageID, newTopic):
            client.submit(
                .moveMessageToTopic(
                    requestID: id,
                    key: key,
                    messageID: messageID,
                    newTopic: newTopic
                )
            )
        }
        return true
    }

    private func applyTopicUpdate(_ update: LiveTopicUpdate, action _: TopicAction) {
        let oldKey = ConversationKey.topic(
            accountID: update.accountID,
            streamID: update.streamID,
            topic: update.oldTopic
        )
        let newKey = ConversationKey.topic(
            accountID: update.accountID,
            streamID: update.streamID,
            topic: update.newTopic
        )
        if update.propagation == .changeAll {
            let previous = knownTopics.removeValue(forKey: oldKey)
            knownTopics[newKey] = LiveTopicSnapshot(
                streamID: update.streamID,
                name: update.newTopic,
                maxMessageID: max(previous?.maxMessageID ?? 0, update.messageID)
            )
            rebuildPresentation()
            if activeSelection == oldKey {
                requestedTopicNavigation = newKey
            }
        } else {
            knownTopics[newKey] = LiveTopicSnapshot(
                streamID: update.streamID,
                name: update.newTopic,
                maxMessageID: max(knownTopics[newKey]?.maxMessageID ?? 0, update.messageID)
            )
            rebuildPresentation()
            if let activeSelection {
                refreshConversation(activeSelection)
            }
        }
    }

    private func rebuildPresentation() {
        guard let sidebar = sidebarSnapshot else {
            return
        }
        let topics = Array(knownTopics.values)
        let channels = sidebar.channels.map { channel in
            ChannelSnapshot(
                streamID: channel.streamID,
                name: channel.name,
                colorHex: channel.colorHex,
                unreadCount: channel.unreadCount,
                isMuted: channel.isMuted,
                topics: topics
                    .filter { $0.streamID == channel.streamID }
                    .sorted {
                        if $0.maxMessageID == $1.maxMessageID {
                            return $0.name.localizedCaseInsensitiveCompare($1.name)
                                == .orderedAscending
                        }
                        return $0.maxMessageID > $1.maxMessageID
                    }
                    .map {
                        TopicSnapshot(
                            streamID: $0.streamID,
                            name: $0.name,
                            maxMessageID: $0.maxMessageID
                        )
                    }
            )
        }
        let updated = SidebarSnapshot(
            accountID: sidebar.accountID,
            organizationName: sidebar.organizationName,
            organizationHost: sidebar.organizationHost,
            quickLinks: sidebar.quickLinks,
            channels: channels,
            directMessages: sidebar.directMessages,
            currentUserName: sidebar.currentUserName,
            currentUserInitials: sidebar.currentUserInitials,
            organizationIconURL: sidebar.organizationIconURL,
            currentUserAvatarURL: sidebar.currentUserAvatarURL
        )
        sidebarSnapshot = updated
        navigationDirectory = Self.makeDirectory(sidebar: updated, topics: topics)
    }

    private var organizationName: String {
        sidebarSnapshot?.organizationName ?? "Live Zulip"
    }

    private func nextRequestID() -> UInt64 {
        defer { requestID &+= 1 }
        return requestID
    }

    static func accountID(serverURL: String, email: String) -> String {
        let normalizedServer = serverURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            .lowercased()
        return "\(normalizedServer)|\(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private static func validatedTopicName(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 1_024,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return nil
        }
        return value
    }

    /// Newest message ID per one-to-one conversation partner, so the list can put
    /// whoever wrote (or was written to) most recently first. The server's recent
    /// conversation list seeds the result and live messages raise it. Group
    /// conversations are not listed in the sidebar and so do not count.
    static func directMessageRecency(
        in messages: [LiveMessageSnapshot],
        currentUserID: Int64,
        serverConversations: [LiveRecentDirectConversation] = []
    ) -> [Int64: Int64] {
        var newest: [Int64: Int64] = [:]
        for conversation in serverConversations {
            let others = Set(conversation.userIDs.filter { $0 > 0 && $0 != currentUserID })
            let partner: Int64
            if others.isEmpty {
                partner = currentUserID
            } else if others.count == 1, let only = others.first {
                partner = only
            } else {
                continue
            }
            newest[partner] = max(newest[partner] ?? 0, conversation.maxMessageID)
        }
        for message in messages where message.streamID == nil {
            let others = Set(message.recipientIDs.filter { $0 > 0 && $0 != currentUserID })
            let partner: Int64
            if others.isEmpty {
                partner = currentUserID
            } else if others.count == 1, let only = others.first {
                partner = only
            } else {
                continue
            }
            newest[partner] = max(newest[partner] ?? 0, message.messageID)
        }
        return newest
    }

    private static func makeSidebar(
        snapshot: LiveSnapshot,
        identity: LiveSessionIdentity,
        topics: [LiveTopicSnapshot],
        presence: [Int64: PresenceState] = [:]
    ) -> SidebarSnapshot {
        let host = URL(string: identity.serverURL)?.host ?? identity.serverURL
        let organization = host.split(separator: ".").first
            .map { String($0).capitalized } ?? host
        let currentName = identity.fullName.isEmpty ? identity.email : identity.fullName
        let recency = directMessageRecency(
            in: snapshot.messages,
            currentUserID: identity.userID,
            serverConversations: snapshot.recentDirectConversations
        )
        let directMessages = snapshot.users
            .filter {
                $0.isActive
            }
            .map {
                DirectMessageSnapshot(
                    userID: $0.userID,
                    displayName: $0.userID == identity.userID
                        ? "\(currentName) (you)"
                        : $0.fullName,
                    initials: initials(for: $0.fullName),
                    presence: presence[$0.userID] ?? .offline,
                    avatarURL: $0.avatarURL
                )
            }
            .sorted {
                let first = recency[$0.userID] ?? 0
                let second = recency[$1.userID] ?? 0
                if first != second {
                    return first > second
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }

        return SidebarSnapshot(
            accountID: identity.accountID,
            organizationName: organization,
            organizationHost: host,
            quickLinks: [
                QuickLinkSnapshot(
                    key: .inbox(accountID: identity.accountID),
                    title: "Inbox",
                    systemImage: "tray.full"
                ),
                QuickLinkSnapshot(
                    key: .mentions(accountID: identity.accountID),
                    title: "Mentions",
                    systemImage: "at"
                ),
                QuickLinkSnapshot(
                    key: .starred(accountID: identity.accountID),
                    title: "Starred",
                    systemImage: "star"
                ),
                QuickLinkSnapshot(
                    key: .unread(accountID: identity.accountID),
                    title: "Unread",
                    systemImage: "circle.fill"
                ),
            ],
            channels: snapshot.channels.map { channel in
                let channelTopics = topics
                    .filter { $0.streamID == channel.streamID }
                return ChannelSnapshot(
                    streamID: channel.streamID,
                    name: channel.name,
                    colorHex: channel.colorHex,
                    isMuted: channel.isMuted,
                    topics: channelTopics
                        .sorted { $0.maxMessageID > $1.maxMessageID }
                        .map {
                            TopicSnapshot(
                                streamID: $0.streamID,
                                name: $0.name,
                                maxMessageID: $0.maxMessageID
                            )
                        }
                )
            },
            directMessages: directMessages,
            currentUserName: currentName,
            currentUserInitials: initials(for: currentName),
            organizationIconURL: snapshot.realmIconURL,
            currentUserAvatarURL: snapshot.users
                .first { $0.userID == identity.userID }?.avatarURL
        )
    }

    private static func makeDirectory(
        sidebar: SidebarSnapshot,
        topics: [LiveTopicSnapshot]
    ) -> NavigationDirectory {
        let quickLinks = sidebar.quickLinks.map {
            NavigationDestination(
                key: $0.key,
                title: $0.title,
                subtitle: sidebar.organizationName,
                systemImage: $0.systemImage,
                keywords: ["navigation", "unread"]
            )
        }
        let channels = sidebar.channels.map {
            NavigationDestination(
                key: .channel(
                    accountID: sidebar.accountID,
                    streamID: $0.streamID
                ),
                title: $0.name,
                subtitle: "Channel",
                systemImage: "number",
                keywords: ["stream", "channel"]
            )
        }
        let channelNames = Dictionary(
            uniqueKeysWithValues: sidebar.channels.map { ($0.streamID, $0.name) }
        )
        var seenTopics = Set<ConversationKey>()
        let topicDestinations = topics
            .sorted {
                if $0.streamID == $1.streamID {
                    return $0.maxMessageID > $1.maxMessageID
                }
                return $0.streamID < $1.streamID
            }
            .compactMap { topic -> NavigationDestination? in
                let streamID = topic.streamID
                let topicName = topic.name
                let key = ConversationKey.topic(
                    accountID: sidebar.accountID,
                    streamID: streamID,
                    topic: topicName
                )
                guard seenTopics.insert(key).inserted else {
                    return nil
                }
                let channel = channelNames[streamID] ?? "channel"
                return NavigationDestination(
                    key: key,
                    title: topicName.isEmpty ? "(no topic)" : topicName,
                    subtitle: "#\(channel)",
                    systemImage: "text.bubble",
                    keywords: ["topic", channel]
                )
            }
        let directMessages = sidebar.directMessages.map {
            NavigationDestination(
                key: .directMessage(
                    accountID: sidebar.accountID,
                    recipientIDs: [$0.userID]
                ),
                title: $0.displayName,
                subtitle: "Direct message",
                systemImage: "person.crop.circle",
                keywords: ["dm", "person", $0.initials]
            )
        }
        return NavigationDirectory(
            destinations: quickLinks + channels + topicDestinations + directMessages
        )
    }

    private static func initials(for name: String) -> String {
        let letters = name
            .split(whereSeparator: \.isWhitespace)
            .prefix(2)
            .compactMap(\.first)
        let result = String(letters).uppercased()
        return result.isEmpty ? "?" : result
    }
}
