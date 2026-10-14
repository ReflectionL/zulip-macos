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
    case reaction(messageID: Int64, target: ReactionTarget, add: Bool)
    case flag(messageID: Int64, flag: LiveMessageFlag, add: Bool)

    var messageID: Int64 {
        switch self {
        case let .edit(messageID, _),
             let .delete(messageID),
             let .reaction(messageID, _, _),
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

enum ChannelCreationState: Equatable, Sendable {
    case idle
    case creating
    case failed(message: String)
    case created(name: String)
}

enum ChannelRenameState: Equatable, Sendable {
    case idle
    case renaming
    case failed(message: String)
    case renamed(name: String)
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
    private static let conversationPageSize: UInt16 = 50
    private static let searchResultLimit: UInt16 = 20
    private static let searchContextRadius: UInt16 = 10

    var authenticationMethod = LiveAuthenticationMethod.password
    var serverURL = LiveSessionViewModel.defaultServerURL
    var email = ""
    var secret = ""
    var connectionState = LiveConnectionState.signedOut
    var notice: String?
    /// Zulip's account-wide default: whether channels without a setting of their
    /// own notify for every message.
    private(set) var channelNotificationsDefault = false
    private(set) var identity: LiveSessionIdentity?
    private(set) var sidebarSnapshot: SidebarSnapshot?
    private(set) var navigationDirectory = NavigationDirectory(destinations: [])
    private(set) var conversationState = ConversationLoadState.loading(
        title: "Mentions",
        subtitle: "Live Zulip"
    )
    private(set) var isLoadingOlderMessages = false
    private(set) var messageSearchState = MessageSearchState.idle
    private(set) var topicActionState = TopicActionState.idle
    private(set) var requestedTopicNavigation: ConversationKey?
    private(set) var attachmentUploadState = AttachmentUploadState.idle
    /// The conversation the current or last upload belongs to.
    private(set) var attachmentUploadKey: ConversationKey?
    private(set) var attachmentInsertion: ComposerAttachmentInsertion?
    private(set) var mediaLocalURLs: [String: String] = [:]
    private(set) var mediaFailures: [String: String] = [:]

    @ObservationIgnored private let client: any CoreClientProtocol
    @ObservationIgnored private let credentialStore: any CredentialStore
    /// The key last read from or written to the Keychain, so a session started from
    /// it does not write the same key back.
    @ObservationIgnored private var storedCredential: StoredAPICredential?
    @ObservationIgnored private var credentialSave: Task<Void, Never>?
    /// The newest live snapshot not yet applied, and the task that applies it.
    @ObservationIgnored private var pendingSnapshot: LiveSnapshot?
    @ObservationIgnored private var snapshotApply: Task<Void, Never>?
    /// The user list the mention candidates were last built from.
    @ObservationIgnored private var candidateUsers: (ownUserID: Int64, users: [LiveUserSnapshot])?
    /// Keeps App Nap from throttling the app while it waits for new messages.
    @ObservationIgnored private var listeningActivity: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifier: (any MessageNotifier)?
    @ObservationIgnored private var notificationPlanner = NotificationPlanner()
    @ObservationIgnored var isApplicationActive: () -> Bool = { NSApplication.shared.isActive }
    /// Locked screen, sleeping display or switched-out login session: the app can
    /// still be frontmost, but nobody is reading.
    @ObservationIgnored let userAttention = UserAttention()
    @ObservationIgnored private var unreadSummary = UnreadSummary()
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
    /// How long a conversation may stay in its loading state before the screen
    /// offers Try Again, whatever the core is doing. The core has its own request
    /// deadlines; this only guarantees the screen can never wait forever.
    @ObservationIgnored var openTimeout = Duration.seconds(25)
    @ObservationIgnored private var openWatchdog: Task<Void, Never>?
    @ObservationIgnored private var recentPageOrder: [ConversationKey] = []
    private static let recentPageLimit = 24
    @ObservationIgnored private var presenceStates: [Int64: PresenceState] = [:]
    @ObservationIgnored private var lastActiveDates: [Int64: Date] = [:]
    /// Bumps whenever presence is refreshed, so views showing it redraw.
    private(set) var presenceRevision = 0
    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    /// People currently typing, by conversation, with the time their typing
    /// notice expires (the server sends no stop when a client just goes quiet).
    private(set) var typingUsers: [ConversationKey: [Int64: Date]] = [:]
    @ObservationIgnored private var typingPruneTask: Task<Void, Never>?
    /// The conversation the user is typing in and when that was last announced.
    @ObservationIgnored private var localTyping: (key: ConversationKey, announcedAt: Date)?
    @ObservationIgnored private var localTypingStopTask: Task<Void, Never>?
    private static let typingExpiry: TimeInterval = 15
    private static let typingAnnounceInterval: TimeInterval = 10
    private static let typingIdleDelay: Duration = .seconds(5)
    @ObservationIgnored private var userNames: [Int64: String] = [:]
    /// Readers of the user's recent sent messages, by message identifier.
    @ObservationIgnored private var readReceiptReaders: [Int64: [Int64]] = [:]
    @ObservationIgnored private var readReceiptRequestDates: [Int64: Date] = [:]
    @ObservationIgnored private var unavailableReadReceiptMessages = Set<Int64>()
    /// Consecutive messages the server could not report; two in a row mean the server
    /// is too old or the organization turned read receipts off, so we stop asking.
    @ObservationIgnored private var unavailableReadReceiptStreak = 0
    @ObservationIgnored private var readReceiptsDisabled = false
    /// Bumps whenever read receipts change, so views showing them redraw.
    private(set) var readReceiptRevision = 0
    private static let readReceiptCacheLimit = 64
    private(set) var drafts: [ConversationKey: String] = [:]
    @ObservationIgnored private var draftSaveTasks: [ConversationKey: Task<Void, Never>] = [:]
    private var requestID: UInt64 = 1
    private var activeSelection: ConversationKey?
    private var pendingOlderRequestID: UInt64?
    /// Conversation opens the user asked for that have not produced a page yet.
    private var openRequests: [UInt64: ConversationKey] = [:]
    /// Notification setting writes awaiting the server's answer.
    private var notificationSettingRequests = Set<UInt64>()
    /// Refreshes and mark-read requests: when one fails the screen stays as it
    /// is and the connection is not reported as failed.
    private var quietRequestIDs = Set<UInt64>()
    /// Newest open request already shown per conversation, so a slow older
    /// response cannot replace a newer page.
    private var lastShownOpenRequestID: [ConversationKey: UInt64] = [:]
    private var pendingSearchRequestID: UInt64?
    private var pendingSearchQuery: String?
    private var issuedSearchRequestIDs = Set<UInt64>()
    private var pendingFocusedMessageRequestID: UInt64?
    private var issuedFocusedMessageRequestIDs = Set<UInt64>()
    private var topicActionsByRequestID: [UInt64: TopicAction] = [:]
    @ObservationIgnored private var messageSourceRequests: [UInt64: PendingMessageSource] = [:]
    @ObservationIgnored private var channelCreationRequestID: UInt64?
    @ObservationIgnored private var mentionPeople: [MentionCandidate] = []
    /// People who can be added to a new channel (everyone active except the user).
    private(set) var channelMemberCandidates: [MentionCandidate] = []
    private(set) var channelCreationState = ChannelCreationState.idle
    private(set) var channelRenameState = ChannelRenameState.idle
    @ObservationIgnored private var channelRenameRequestID: UInt64?
    private var messageActionsByRequestID: [UInt64: SubmittedMessageAction] = [:]
    private var failedMessageActions: [Int64: MessageAction] = [:]
    private var sendsByRequestID: [UInt64: PendingSend] = [:]
    private var failedSends: [Int64: PendingSend] = [:]
    /// Server message ID -> local echo ID for sends the server accepted but whose
    /// rendered copy has not been fetched yet; the echo stays visible until then.
    private var confirmedEchoes: [Int64: Int64] = [:]
    private var attachmentUploadsByRequestID: [UInt64: PendingAttachmentUpload] = [:]
    private var failedAttachmentUpload: PendingAttachmentUpload?
    private var queuedAttachmentUploads: [(URL, ConversationKey)] = []
    private var mediaRequestsByRequestID: [UInt64: String] = [:]
    private var pendingMediaURLs = Set<String>()
    /// Media wanted while only cached data is shown; the core has no account
    /// session to download with until the live session starts.
    private var deferredMediaURLs = Set<String>()
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
            self?.applicationBecameActive()
        }
        userAttention.onReturn = { [weak self] in
            self?.userReturned()
        }
        notifier?.onNotificationsDisabled = { [weak self] in
            self?.notice = "Notifications are turned off for Zulip Mac. "
                + "Turn them on in System Settings › Notifications."
        }
    }

    /// Messages that arrived while the app was in the background were not marked
    /// read, so the open conversation is read now that the user is looking at it.
    private func applicationBecameActive() {
        guard let activeSelection, case .loaded = conversationState else {
            return
        }
        refreshConversation(activeSelection)
    }

    /// Whether the user can be reading right now: the app is frontmost and the
    /// screen is neither locked nor asleep.
    private func isUserPresent() -> Bool {
        isApplicationActive() && !userAttention.isAway
    }

    /// Unlocking or waking the display does not reactivate an app that stayed
    /// frontmost, so what arrived meanwhile is read here.
    private func userReturned() {
        guard isApplicationActive() else {
            return
        }
        applicationBecameActive()
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
            if isUserPresent(), activeSelection == notification.route.key {
                continue
            }
            notifier.post(notification)
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

    /// The composer of `key` gained or lost text. Others see "typing" while text
    /// keeps changing; it is announced again every few seconds and withdrawn
    /// when the box empties, the user goes quiet, or the conversation changes.
    func composerTyping(_ hasText: Bool, in key: ConversationKey) {
        guard hasLiveSession, supportsTypingNotices(key) else {
            return
        }
        guard hasText else {
            if localTyping?.key == key {
                stopLocalTyping()
            }
            return
        }
        if let current = localTyping, current.key != key {
            stopLocalTyping()
        }
        let now = Date.now
        let announcedRecently = localTyping.map {
            now.timeIntervalSince($0.announcedAt) < Self.typingAnnounceInterval
        } ?? false
        if !announcedRecently {
            client.submit(.setTyping(requestID: nextRequestID(), key: key, isTyping: true))
            localTyping = (key, now)
        }
        localTypingStopTask?.cancel()
        localTypingStopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.typingIdleDelay)
            guard !Task.isCancelled else { return }
            self?.stopLocalTyping()
        }
    }

    private func stopLocalTyping() {
        localTypingStopTask?.cancel()
        localTypingStopTask = nil
        guard let current = localTyping else {
            return
        }
        localTyping = nil
        client.submit(.setTyping(requestID: nextRequestID(), key: current.key, isTyping: false))
    }

    /// Typing notices exist for topics and for conversations with other people.
    private func supportsTypingNotices(_ key: ConversationKey) -> Bool {
        switch key {
        case .topic:
            true
        case let .directMessage(_, recipientIDs):
            !recipientIDs.isEmpty && recipientIDs != [identity?.userID ?? 0]
        default:
            false
        }
    }

    /// "Theo is typing…" for the people typing in `key`, or nil when nobody is.
    func typingDescription(for key: ConversationKey) -> String? {
        let names = (typingUsers[key] ?? [:])
            .keys
            .sorted()
            .map { userNames[$0] ?? "Someone" }
        switch names.count {
        case 0: return nil
        case 1: return "\(names[0]) is typing…"
        case 2: return "\(names[0]) and \(names[1]) are typing…"
        default: return "Several people are typing…"
        }
    }

    private func applyTyping(
        accountID: String,
        key: ConversationKey,
        senderID: Int64,
        isTyping: Bool
    ) {
        guard identity?.accountID == accountID, senderID != identity?.userID else {
            return
        }
        if isTyping {
            typingUsers[key, default: [:]][senderID] = Date.now.addingTimeInterval(Self.typingExpiry)
            startPruningTyping()
        } else {
            typingUsers[key]?.removeValue(forKey: senderID)
            if typingUsers[key]?.isEmpty == true {
                typingUsers.removeValue(forKey: key)
            }
        }
    }

    private func startPruningTyping() {
        guard typingPruneTask == nil else {
            return
        }
        typingPruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.pruneTyping(now: .now)
                if self.typingUsers.isEmpty {
                    self.typingPruneTask = nil
                    return
                }
            }
        }
    }

    private func pruneTyping(now: Date) {
        for (key, users) in typingUsers {
            let active = users.filter { $0.value > now }
            if active.isEmpty {
                typingUsers.removeValue(forKey: key)
            } else if active.count != users.count {
                typingUsers[key] = active
            }
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
            storedCredential = credential
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
        if localTyping?.key != key {
            stopLocalTyping()
        }
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
        let openID = nextRequestID()
        openRequests[openID] = key
        client.submit(
            .openConversation(
                requestID: openID,
                key: key,
                limit: Self.conversationPageSize
            )
        )
        openWatchdog?.cancel()
        openWatchdog = Task { [weak self, openTimeout] in
            try? await Task.sleep(for: openTimeout)
            guard !Task.isCancelled else { return }
            self?.openRequestTimedOut(openID, key: key)
        }
    }

    /// Replaces a loading state that has outlived its welcome by a failure with a
    /// Try Again button. A late page still replaces the failure when it arrives.
    private func openRequestTimedOut(_ requestID: UInt64, key: ConversationKey) {
        guard openRequests[requestID] == key,
              activeSelection == key,
              case .loading = conversationState
        else {
            return
        }
        let destination = navigationDirectory.destination(for: key)
        conversationState = .failure(
            title: destination?.title ?? "Conversation",
            subtitle: destination?.subtitle ?? organizationName,
            message: "The server did not answer in time. Check the connection and try again."
        )
    }

    /// Asks for the open conversation's first page again after a failure.
    func retryOpenConversation() {
        guard let activeSelection else {
            return
        }
        openConversation(activeSelection)
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
        case let .channel(_, streamID):
            // Writing in a channel without picking a topic goes to its default
            // topic, which Zulip stores as an empty name ("general chat").
            client.submit(
                .sendChannelMessage(
                    requestID: id,
                    accountID: identity.accountID,
                    streamID: streamID,
                    topic: "",
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

    /// Reacts with `target`, or withdraws the user's own reaction when they already
    /// used it. Joining an existing group reuses that group's emoji name.
    @discardableResult
    func toggleReaction(_ message: MessageViewData, _ target: ReactionTarget) -> Bool {
        let existing = message.reaction(matching: target)
        let add = existing?.includesMe != true
        let chosen = existing.map(\.target) ?? target
        return submitMessageAction(
            .reaction(messageID: message.id, target: chosen, add: add)
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

    /// People the composer can offer after `@`; group mentions only make sense in a topic.
    func mentionCandidates(for key: ConversationKey) -> [MentionCandidate] {
        guard case .topic = key else {
            return mentionPeople
        }
        return [
            MentionCandidate(kind: .everyone, name: "all", detail: "Notify everyone in the channel"),
            MentionCandidate(kind: .topic, name: "topic", detail: "Notify people in this topic"),
        ] + mentionPeople
    }

    /// Creates a channel and subscribes the chosen people (and the user) to it.
    func createChannel(
        name: String,
        description: String,
        isPrivate: Bool,
        memberIDs: [Int64]
    ) {
        guard let identity else {
            return
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= 60,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            channelCreationState = .failed(
                message: "Enter a channel name of up to 60 characters."
            )
            return
        }
        if sidebarSnapshot?.channels.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) == true {
            channelCreationState = .failed(message: "A channel named “\(name)” already exists.")
            return
        }
        if case .creating = channelCreationState {
            return
        }
        var members = Array(Set(memberIDs.filter { $0 > 0 && $0 != identity.userID }))
        members.sort()
        let id = nextRequestID()
        channelCreationRequestID = id
        channelCreationState = .creating
        client.submit(
            .createChannel(
                requestID: id,
                accountID: identity.accountID,
                name: name,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                isPrivate: isPrivate,
                memberIDs: [identity.userID] + members
            )
        )
    }

    func resetChannelCreation() {
        channelCreationRequestID = nil
        channelCreationState = .idle
    }

    /// Renames a channel. Whether the user may is the server's call; its refusal is
    /// shown in the rename sheet.
    func renameChannel(streamID: Int64, to newName: String) {
        guard let identity else {
            return
        }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= 60,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            channelRenameState = .failed(message: "Enter a channel name of up to 60 characters.")
            return
        }
        guard let current = sidebarSnapshot?.channels.first(where: { $0.streamID == streamID }) else {
            channelRenameState = .failed(message: "This channel is no longer available.")
            return
        }
        if current.name == name {
            channelRenameState = .failed(message: "Enter a different name.")
            return
        }
        if sidebarSnapshot?.channels.contains(where: {
            $0.streamID != streamID
                && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) == true {
            channelRenameState = .failed(message: "A channel named “\(name)” already exists.")
            return
        }
        if case .renaming = channelRenameState {
            return
        }
        let id = nextRequestID()
        channelRenameRequestID = id
        channelRenameState = .renaming
        client.submit(
            .renameChannel(
                requestID: id,
                accountID: identity.accountID,
                streamID: streamID,
                newName: name
            )
        )
    }

    /// Turns notifications for every message of one channel on or off, in Zulip
    /// itself, so the web app and other clients agree. The sidebar follows once
    /// the server's update arrives with the next snapshot.
    func setChannelNotifications(streamID: Int64, enabled: Bool) {
        submitNotificationSetting(streamID: streamID, enabled: enabled)
    }

    /// Sets Zulip's account-wide default for channels without a setting of their own.
    func setChannelNotificationsDefault(_ enabled: Bool) {
        submitNotificationSetting(streamID: nil, enabled: enabled)
    }

    /// Sets one topic to Followed, Default or Muted in Zulip itself (`.unmuted`
    /// is for topics inside a muted channel). The sidebar follows once the
    /// server's `user_topic` update arrives with the next snapshot.
    func setTopicNotification(streamID: Int64, topic: String, level: TopicNotificationLevel) {
        guard let identity, hasLiveSession else {
            notice = "Notification settings can be changed once you are connected."
            return
        }
        let id = nextRequestID()
        notificationSettingRequests.insert(id)
        client.submit(
            .setTopicNotification(
                requestID: id,
                accountID: identity.accountID,
                streamID: streamID,
                topic: topic,
                level: level
            )
        )
    }

    private func submitNotificationSetting(streamID: Int64?, enabled: Bool) {
        guard let identity, hasLiveSession else {
            notice = "Notification settings can be changed once you are connected."
            return
        }
        let id = nextRequestID()
        notificationSettingRequests.insert(id)
        client.submit(
            .setNotificationSetting(
                requestID: id,
                accountID: identity.accountID,
                streamID: streamID,
                enabled: enabled
            )
        )
    }

    func resetChannelRename() {
        channelRenameRequestID = nil
        channelRenameState = .idle
    }

    /// Whether someone is online, or how long ago they were last active.
    func presenceDescription(forUserID userID: Int64) -> String? {
        _ = presenceRevision
        guard userID != identity?.userID else {
            return nil
        }
        return PresenceDescription.text(
            state: presenceStates[userID] ?? .offline,
            lastActive: lastActiveDates[userID]
        )
    }

    /// The header status of a one-to-one conversation.
    func presenceDescription(for key: ConversationKey) -> String? {
        guard case let .directMessage(_, recipientIDs) = key,
              recipientIDs.count == 1,
              let userID = recipientIDs.first
        else {
            return nil
        }
        return presenceDescription(forUserID: userID)
    }

    /// The user's newest sent message in `page` with the people who have read it,
    /// or nil where read receipts do not apply or the server cannot provide them.
    func readReceiptDisplay(for page: ConversationPage) -> ReadReceiptDisplay? {
        _ = readReceiptRevision
        guard !readReceiptsDisabled,
              let identity,
              let messageID = ReadReceiptPolicy.targetMessageID(
                  in: page.messages,
                  key: page.key,
                  selfUserID: identity.userID
              ),
              !unavailableReadReceiptMessages.contains(messageID)
        else {
            return nil
        }
        let readers = (readReceiptReaders[messageID] ?? []).compactMap { userID -> ReadReceiptReader? in
            guard userID != identity.userID, let name = userNames[userID] else {
                return nil
            }
            return ReadReceiptReader(
                userID: userID,
                name: name,
                initials: Self.initials(for: name),
                avatarURL: avatarURLs[userID]
            )
        }
        return ReadReceiptDisplay(messageID: messageID, readers: readers)
    }

    /// Asks who has read `messageID` unless the app is inactive, offline or asked
    /// moments ago. Returns false once asking again cannot help, which ends polling.
    func pollReadReceipts(messageID: Int64, key: ConversationKey) -> Bool {
        guard !readReceiptsDisabled,
              let identity,
              identity.accountID == key.accountID,
              messageID > 0,
              !unavailableReadReceiptMessages.contains(messageID),
              !ReadReceiptPolicy.isComplete(
                  readerIDs: readReceiptReaders[messageID] ?? [],
                  key: key,
                  selfUserID: identity.userID
              )
        else {
            return false
        }
        let now = Date()
        if connectionState == .connected,
           isUserPresent(),
           now.timeIntervalSince(readReceiptRequestDates[messageID] ?? .distantPast)
               >= ReadReceiptPolicy.minimumRequestInterval
        {
            readReceiptRequestDates[messageID] = now
            client.submit(
                .fetchReadReceipts(
                    requestID: nextRequestID(),
                    accountID: identity.accountID,
                    messageID: messageID
                )
            )
        }
        return true
    }

    private func applyReadReceipts(messageID: Int64, userIDs: [Int64], isAvailable: Bool) {
        if isAvailable {
            unavailableReadReceiptStreak = 0
            guard readReceiptReaders[messageID] != userIDs else {
                return
            }
            readReceiptReaders[messageID] = userIDs
            for staleID in readReceiptReaders.keys.sorted().dropLast(Self.readReceiptCacheLimit) {
                readReceiptReaders.removeValue(forKey: staleID)
                readReceiptRequestDates.removeValue(forKey: staleID)
            }
        } else {
            unavailableReadReceiptMessages.insert(messageID)
            unavailableReadReceiptStreak += 1
            if unavailableReadReceiptStreak >= 2 {
                readReceiptsDisabled = true
                readReceiptReaders = [:]
            }
        }
        readReceiptRevision += 1
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
        case let .channel(_, streamID):
            client.submit(
                .sendChannelMessage(
                    requestID: id,
                    accountID: send.key.accountID,
                    streamID: streamID,
                    topic: "",
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
        attachmentUploadKey = key
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

    /// Entry point for files dropped on the conversation. The first file uploads
    /// now and the rest follow one at a time, because the composer tracks a
    /// single upload; a failure drops whatever is still queued.
    func uploadDroppedFiles(_ urls: [URL], to key: ConversationKey) {
        let files = urls.filter { url in
            guard url.isFileURL else { return false }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory != true
        }
        guard let first = files.first else {
            notice = "Only files can be uploaded. Drag a file from Finder onto the conversation."
            return
        }
        guard !attachmentUploadState.isUploading else {
            notice = "Wait for the current upload to finish before adding more files."
            return
        }
        queuedAttachmentUploads = files.dropFirst().map { ($0, key) }
        uploadAttachment(first, to: key)
    }

    private func startNextQueuedUpload() {
        guard !queuedAttachmentUploads.isEmpty else { return }
        let next = queuedAttachmentUploads.removeFirst()
        guard activeSelection == next.1 else {
            queuedAttachmentUploads = []
            return
        }
        uploadAttachment(next.0, to: next.1)
    }

    func retryAttachmentUpload() {
        guard let failedAttachmentUpload else { return }
        uploadAttachment(failedAttachmentUpload.fileURL, to: failedAttachmentUpload.key)
    }

    /// The upload state to show in `key`'s composer: an upload or its failure
    /// shows only in the conversation it was started from.
    func attachmentUploadState(for key: ConversationKey) -> AttachmentUploadState {
        attachmentUploadKey == key ? attachmentUploadState : .idle
    }

    /// Closes a failed upload's message without retrying it.
    func dismissAttachmentUploadFailure() {
        guard case .failed = attachmentUploadState else { return }
        failedAttachmentUpload = nil
        attachmentUploadState = .idle
    }

    func consumeAttachmentInsertion(id: UInt64) {
        guard attachmentInsertion?.id == id else { return }
        attachmentInsertion = nil
    }

    func loadMedia(_ remoteURL: String) {
        guard !remoteURL.isEmpty,
              mediaLocalURLs[remoteURL] == nil,
              !pendingMediaURLs.contains(remoteURL)
        else { return }
        guard let identity, hasLiveSession else {
            // Asked for before the live session exists: requested once it does.
            deferredMediaURLs.insert(remoteURL)
            return
        }
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

    /// Requests the avatars, organization icon, and images asked for before the
    /// live session existed (their first attempt could not have succeeded).
    private func requestDeferredMedia() {
        let urls = deferredMediaURLs.union(mediaFailures.keys)
        deferredMediaURLs = []
        for remoteURL in urls.sorted() {
            loadMedia(remoteURL)
        }
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
            openConversation(Self.landingConversation(accountID: identity.accountID))

        case let .sessionStarted(_, identity, credential, snapshot):
            cancelReconnect()
            // A snapshot of the session this one replaces must not land on top.
            pendingSnapshot = nil
            hasLiveSession = true
            self.identity = identity
            serverURL = identity.serverURL
            email = identity.email
            rememberLastAccount(identity)
            apply(snapshot)
            requestDeferredMedia()
            notificationPlanner.prime(with: snapshot)
            notifier?.requestAuthorization()
            loadDrafts(for: identity.accountID)
            startPresenceUpdates(accountID: identity.accountID)
            saveCredential(credential)
            keepListeningInBackground()
            connectionState = .connected
            if let activeSelection, activeSelection.accountID == identity.accountID {
                // Keep the user's place when a cached session went live.
                refreshConversation(activeSelection)
            } else {
                openConversation(Self.landingConversation(accountID: identity.accountID))
            }

        case let .snapshotUpdated(accountID, snapshot):
            guard identity?.accountID == accountID else {
                return
            }
            connectionState = .connected
            // Every snapshot is complete, so in a burst only the newest needs
            // applying, and the pages and events queued behind it must not wait
            // while each older one is applied in turn.
            pendingSnapshot = snapshot
            if snapshotApply == nil {
                snapshotApply = Task { [weak self] in
                    await Task.yield()
                    self?.applyPendingSnapshot()
                }
            }

        case let .conversationOpened(requestID, page):
            openRequests[requestID] = nil
            quietRequestIDs.remove(requestID)
            guard pendingFocusedMessageRequestID == nil,
                  activeSelection == page.key,
                  requestID > (lastShownOpenRequestID[page.key] ?? 0)
            else {
                return
            }
            lastShownOpenRequestID[page.key] = requestID
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
            // While the app is in the background or the screen is locked the user
            // cannot be reading these; `applicationBecameActive` marks them read
            // once they return.
            let messageIDs = page.messages.map(\.messageID)
            if !messageIDs.isEmpty, let identity, isUserPresent(),
               Self.marksMessagesRead(in: page.key)
            {
                submitMarkRead(accountID: identity.accountID, messageIDs: messageIDs)
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
            if !messageIDs.isEmpty, let identity, Self.marksMessagesRead(in: page.key) {
                submitMarkRead(accountID: identity.accountID, messageIDs: messageIDs)
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
            startNextQueuedUpload()

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

        case let .channelCreated(requestID, name):
            guard channelCreationRequestID == requestID else {
                return
            }
            channelCreationRequestID = nil
            channelCreationState = .created(name: name)
            notice = "Created channel “\(name)”."

        case let .channelRenamed(requestID, _, name):
            guard channelRenameRequestID == requestID else {
                return
            }
            channelRenameRequestID = nil
            channelRenameState = .renamed(name: name)
            notice = "Renamed the channel to “\(name)”."

        case let .notificationSettingSaved(requestID):
            notificationSettingRequests.remove(requestID)

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

        case let .messagesMarkedRead(requestID, _):
            quietRequestIDs.remove(requestID)

        case .pong:
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

        case let .typingChanged(accountID, key, senderID, isTyping):
            applyTyping(accountID: accountID, key: key, senderID: senderID, isTyping: isTyping)

        case let .readReceiptsLoaded(accountID, messageID, userIDs, isAvailable):
            guard identity?.accountID == accountID else {
                return
            }
            applyReadReceipts(messageID: messageID, userIDs: userIDs, isAvailable: isAvailable)

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
            let failedOpenKey = requestID.flatMap { openRequests.removeValue(forKey: $0) }
            let wasQuietRequest = requestID.map { quietRequestIDs.remove($0) != nil } ?? false
            if wasQuietRequest {
                // A refresh or mark-read that did not go through: what is on screen
                // stays, and the next snapshot or visit tries again.
                sessionLog.error("background request failed: \(message, privacy: .public)")
            } else if let requestID, notificationSettingRequests.remove(requestID) != nil {
                notice = "The notification setting could not be saved: \(message)"
            } else if let requestID, requestID == cachedSessionRequestID {
                // No cached data yet (first run); the live connection continues.
                cachedSessionRequestID = nil
            } else if let requestID,
               let pending = attachmentUploadsByRequestID.removeValue(forKey: requestID)
            {
                stopSecurityScope(for: pending)
                queuedAttachmentUploads = []
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
                notice = "Message could not be sent: \(message). You can retry it."
            } else if let requestID, channelCreationRequestID == requestID {
                channelCreationRequestID = nil
                channelCreationState = .failed(
                    message: message.contains("CHANNEL_ALREADY_EXISTS")
                        ? "A channel with this name already exists."
                        : message
                )
            } else if let requestID, channelRenameRequestID == requestID {
                channelRenameRequestID = nil
                channelRenameState = .failed(
                    message: message.contains("CHANNEL_ALREADY_EXISTS")
                        ? "A channel with this name already exists."
                        : message
                )
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
            } else if let failedOpenKey {
                // The first page of a conversation the user opened could not be
                // fetched. Say so instead of leaving the loading placeholder up.
                guard activeSelection == failedOpenKey, case .loading = conversationState else {
                    return
                }
                let destination = navigationDirectory.destination(for: failedOpenKey)
                conversationState = .failure(
                    title: destination?.title ?? "Conversation",
                    subtitle: destination?.subtitle ?? organizationName,
                    message: message
                )
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
                    await credentialSave?.value
                    storedCredential = nil
                    try? await credentialStore.delete(accountID: rejectedAccountID)
                }
                forgetLastAccount()
                connectionState = .failed(message: message)
            } else {
                connectionState = .failed(message: message)
            }
        }
    }

    private func applyPendingSnapshot() {
        snapshotApply = nil
        guard let snapshot = pendingSnapshot else {
            return
        }
        pendingSnapshot = nil
        let shouldRefresh = activeSelection.map {
            conversationAffected(by: snapshot, key: $0)
        } ?? false
        apply(snapshot)
        notifyAboutNewMessages(in: snapshot)
        if shouldRefresh, let activeSelection {
            refreshConversation(activeSelection)
        }
    }

    /// Writes a newly issued key to the Keychain beside the event loop. A Keychain
    /// call can stall (an ad-hoc signed build may wait on a file-keychain access
    /// prompt), and every later core event, including opened conversations and new
    /// messages, used to queue behind it.
    private func saveCredential(_ credential: StoredAPICredential) {
        guard credential != storedCredential else {
            return
        }
        storedCredential = credential
        let store = credentialStore
        let previous = credentialSave
        credentialSave = Task { [weak self] in
            await previous?.value
            do {
                try await store.save(credential)
            } catch {
                self?.storedCredential = nil
                self?.notice = "Connected, but the API key could not be saved in Keychain."
            }
        }
    }

    /// A hidden window lets macOS put the app to sleep (App Nap), which can hold
    /// up the event queue for minutes so a message notifies late or, once the
    /// server drops the stalled queue, not at all. Idle system sleep stays allowed.
    private func keepListeningInBackground() {
        guard listeningActivity == nil else {
            return
        }
        listeningActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Waiting for new Zulip messages"
        )
    }

    private func resetSessionState() {
        hasLiveSession = false
        if let listeningActivity {
            ProcessInfo.processInfo.endActivity(listeningActivity)
            self.listeningActivity = nil
        }
        snapshotMessages = [:]
        avatarURLs = [:]
        presenceTask?.cancel()
        presenceTask = nil
        typingPruneTask?.cancel()
        typingPruneTask = nil
        localTypingStopTask?.cancel()
        localTypingStopTask = nil
        localTyping = nil
        typingUsers = [:]
        presenceStates = [:]
        lastActiveDates = [:]
        userNames = [:]
        readReceiptReaders = [:]
        readReceiptRequestDates = [:]
        unavailableReadReceiptMessages = []
        unavailableReadReceiptStreak = 0
        readReceiptsDisabled = false
        cachedPlaceholderKey = nil
        recentPages = [:]
        recentPageOrder = []
        notificationPlanner.reset()
        unreadSummary = UnreadSummary()
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
        openRequests = [:]
        notificationSettingRequests = []
        channelNotificationsDefault = false
        quietRequestIDs = []
        lastShownOpenRequestID = [:]
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
        queuedAttachmentUploads = []
        attachmentUploadState = .idle
        attachmentUploadKey = nil
        attachmentInsertion = nil
        mediaRequestsByRequestID = [:]
        pendingMediaURLs = []
        deferredMediaURLs = []
        mediaLocalURLs = [:]
        mediaFailures = [:]
        messageSourceRequests = [:]
        channelCreationRequestID = nil
        channelCreationState = .idle
        mentionPeople = []
        channelMemberCandidates = []
        candidateUsers = nil
        pendingSnapshot = nil
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
                isActive: isUserPresent()
            )
        )
    }

    private func applyPresence(_ presences: [LivePresence]) {
        presenceStates = Dictionary(
            presences.map { ($0.userID, $0.state) },
            uniquingKeysWith: { _, latest in latest }
        )
        lastActiveDates = Dictionary(
            presences.compactMap { presence in
                presence.lastActiveAt.map { (presence.userID, $0) }
            },
            uniquingKeysWith: { _, latest in latest }
        )
        presenceRevision += 1
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
        // Most snapshots only change messages; rebuilding (and sorting) every user
        // of a large organization for each of them kept the main thread busy.
        if candidateUsers?.ownUserID != identity.userID || candidateUsers?.users != snapshot.users {
            candidateUsers = (identity.userID, snapshot.users)
            rebuildUserIndexes(snapshot.users, identity: identity)
        }
        replaceKnownTopics(from: snapshot)
        channelNotificationsDefault = snapshot.channelNotificationsDefault
        unreadSummary = UnreadSummary(
            buckets: snapshot.unread,
            selfUserID: identity.userID,
            mutedChannels: Set(snapshot.channels.filter(\.isMuted).map(\.streamID)),
            settings: ChannelNotificationSettings(snapshot: snapshot)
        )
        notifier?.setBadge(unreadSummary.badge)
        sidebarSnapshot = Self.makeSidebar(
            snapshot: snapshot,
            identity: identity,
            topics: Array(knownTopics.values),
            presence: presenceStates,
            unread: unreadSummary
        )
        rebuildPresentation()
    }

    private func rebuildUserIndexes(_ users: [LiveUserSnapshot], identity: LiveSessionIdentity) {
        avatarURLs = Dictionary(
            users.compactMap { user in
                user.avatarURL.map { (user.userID, $0) }
            },
            uniquingKeysWith: { _, latest in latest }
        )
        userNames = Dictionary(
            users.map { ($0.userID, $0.fullName) },
            uniquingKeysWith: { _, latest in latest }
        )
        let others = users
            .filter { $0.isActive && $0.userID != identity.userID }
            .sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
        mentionPeople = others.map {
            MentionCandidate(
                kind: .person(userID: $0.userID),
                name: $0.fullName,
                detail: $0.isBot ? "Bot" : ($0.email ?? "")
            )
        }
        channelMemberCandidates = others
            .filter { !$0.isBot }
            .map {
                MentionCandidate(
                    kind: .person(userID: $0.userID),
                    name: $0.fullName,
                    detail: $0.email ?? ""
                )
            }
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

    /// One entry per emoji, in the order each first appeared. The name shown to
    /// the action is the current user's own when they reacted, otherwise the first used.
    static func groupReactions(
        _ reactions: [LiveReactionSnapshot],
        me: Int64?
    ) -> [MessageReaction] {
        var groups: [MessageReaction] = []
        for reaction in reactions {
            let target = ReactionTarget(
                name: reaction.emojiName,
                code: reaction.emojiCode,
                type: reaction.reactionType
            )
            let isMine = reaction.userID == me
            if let index = groups.firstIndex(where: { target.matches($0) }) {
                groups[index].count += 1
                if isMine, !groups[index].includesMe {
                    groups[index] = MessageReaction(
                        emojiName: reaction.emojiName,
                        emojiCode: groups[index].emojiCode,
                        reactionType: groups[index].reactionType,
                        count: groups[index].count,
                        includesMe: true
                    )
                }
            } else {
                groups.append(
                    MessageReaction(
                        emojiName: reaction.emojiName,
                        emojiCode: reaction.emojiCode,
                        reactionType: reaction.reactionType,
                        count: 1,
                        includesMe: isMine
                    )
                )
            }
        }
        return groups
    }

    private func makeMessages(_ livePage: LiveConversationPage) -> [MessageViewData] {
        livePage.messages.map { message in
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
                reactions: Self.groupReactions(message.reactions, me: identity?.userID),
                isRead: message.flags.contains("read"),
                senderAvatarURL: avatarURLs[message.senderID],
                editedAt: message.lastEditDate
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
        case let .reaction(messageID, target, add):
            client.submit(
                .updateReaction(
                    requestID: id,
                    accountID: identity.accountID,
                    messageID: messageID,
                    emojiName: target.name,
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
                message.editedAt = Date()
            case .delete:
                break
            case let .reaction(_, target, add):
                message.applyReaction(target, add: add)
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
        return messages
            .filter { !localIDs.contains($0.id) }
            .map { message in
                // The server copy takes over the echo's row so the row updates in place.
                guard let localID = resolved[message.id] else {
                    return message
                }
                var inherited = message
                inherited.rowID = localID
                return inherited
            }
    }

    private func appendLocalEcho(_ send: PendingSend, id: Int64) {
        guard let identity,
              case let .loaded(page) = conversationState,
              page.key == send.key
        else {
            return
        }
        let source: (Int64?, String?)
        switch send.key {
        case let .topic(_, streamID, topic):
            source = (streamID, topic)
        case let .channel(_, streamID):
            source = (streamID, "")
        default:
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
            senderAvatarURL: avatarURLs[identity.userID],
            isProvisional: LocalEcho.needsServerRendering(send.content)
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
            title = TopicName.display(topic)
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
        for incoming in second {
            var message = incoming
            if let existing = messagesByID[message.id] {
                if existing.deliveryState != .sent || existing.actionState != .idle {
                    continue
                }
                // Keep the row a replaced echo handed over to this message.
                if existing.rowID != existing.id {
                    message.rowID = existing.rowID
                }
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
        let refreshID = nextRequestID()
        quietRequestIDs.insert(refreshID)
        client.submit(
            .openConversation(
                requestID: refreshID,
                key: key,
                limit: Self.conversationPageSize
            )
        )
    }

    private func submitMarkRead(accountID: String, messageIDs: [Int64]) {
        let id = nextRequestID()
        quietRequestIDs.insert(id)
        client.submit(
            .markRead(requestID: id, accountID: accountID, messageIDs: messageIDs)
        )
    }

    /// The core's topic list follows the server, so a topic it no longer reports
    /// (renamed, moved to another channel, emptied or deleted) leaves the sidebar.
    /// Only topics still waiting for their first message are kept.
    private func replaceKnownTopics(from snapshot: LiveSnapshot) {
        knownTopics = knownTopics.filter { $0.value.maxMessageID == 0 }
        rememberTopics(from: snapshot.topics)
        rememberTopics(from: snapshot.messages)
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
                notifiesForAllMessages: channel.notifiesForAllMessages,
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
                            maxMessageID: $0.maxMessageID,
                            unreadCount: unreadSummary.unreadCount(
                                streamID: $0.streamID,
                                topic: $0.name
                            ),
                            notification: unreadSummary.topicLevel(
                                streamID: $0.streamID,
                                topic: $0.name
                            )
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
        refreshOpenPageTitle()
    }

    /// Keeps the open conversation's title current when its channel is renamed.
    private func refreshOpenPageTitle() {
        switch conversationState {
        case let .loaded(page):
            if let renamed = retitled(page) {
                conversationState = .loaded(renamed)
            }
        case let .offline(page):
            if let renamed = retitled(page) {
                conversationState = .offline(renamed)
            }
        default:
            break
        }
    }

    private func retitled(_ page: ConversationPage) -> ConversationPage? {
        guard let destination = navigationDirectory.destination(for: page.key),
              destination.title != page.title || destination.subtitle != page.subtitle
        else {
            return nil
        }
        return ConversationPage(
            key: page.key,
            title: destination.title,
            subtitle: destination.subtitle,
            messages: page.messages,
            beforeCursor: page.beforeCursor,
            afterCursor: page.afterCursor,
            focusedMessageID: page.focusedMessageID
        )
    }

    private var organizationName: String {
        sidebarSnapshot?.organizationName ?? "Live Zulip"
    }

    /// Whether opening `key` counts as reading what it lists. Collections such as
    /// Mentions or Starred list messages out of context, so opening one must not
    /// clear their unread state; a channel, topic or direct message does.
    static func marksMessagesRead(in key: ConversationKey) -> Bool {
        switch key {
        case .channel, .topic, .directMessage:
            true
        case .inbox, .mentions, .starred, .unread, .drafts:
            false
        }
    }

    /// What the window shows before the user picks something. Inbox and Unread are
    /// no longer offered, so Mentions leads the sidebar and opens first.
    static func landingConversation(accountID: String) -> ConversationKey {
        .mentions(accountID: accountID)
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
            let participants = message.recipientIDs + [message.senderID]
            let others = Set(participants.filter { $0 > 0 && $0 != currentUserID })
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
        presence: [Int64: PresenceState] = [:],
        unread: UnreadSummary = UnreadSummary()
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
                    unreadCount: unread.unreadCount(directMessageWith: $0.userID),
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
                    key: .mentions(accountID: identity.accountID),
                    title: "Mentions",
                    systemImage: "at",
                    unreadCount: unread.mentions
                ),
                QuickLinkSnapshot(
                    key: .starred(accountID: identity.accountID),
                    title: "Starred",
                    systemImage: "star"
                ),
            ],
            channels: snapshot.channels.map { channel in
                let channelTopics = topics
                    .filter { $0.streamID == channel.streamID }
                return ChannelSnapshot(
                    streamID: channel.streamID,
                    name: channel.name,
                    colorHex: channel.colorHex,
                    unreadCount: unread.unreadCount(streamID: channel.streamID),
                    isMuted: channel.isMuted,
                    notifiesForAllMessages: channel.desktopNotifications
                        ?? snapshot.channelNotificationsDefault,
                    topics: channelTopics
                        .sorted { $0.maxMessageID > $1.maxMessageID }
                        .map {
                            TopicSnapshot(
                                streamID: $0.streamID,
                                name: $0.name,
                                maxMessageID: $0.maxMessageID,
                                unreadCount: unread.unreadCount(
                                    streamID: $0.streamID,
                                    topic: $0.name
                                ),
                                notification: unread.topicLevel(
                                    streamID: $0.streamID,
                                    topic: $0.name
                                )
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
                    title: TopicName.display(topicName),
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
