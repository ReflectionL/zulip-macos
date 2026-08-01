import Foundation
import Observation
import ZulipCoreBindings

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

@MainActor
@Observable
final class LiveSessionViewModel {
    static let defaultServerURL = "https://shitcreator.zulipchat.com"
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

    @ObservationIgnored private let client: any CoreClientProtocol
    @ObservationIgnored private let credentialStore: any CredentialStore
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    private var requestID: UInt64 = 1
    private var activeSelection: ConversationKey?
    private var pendingOlderRequestID: UInt64?
    private var pendingSearchRequestID: UInt64?
    private var pendingSearchQuery: String?
    private var issuedSearchRequestIDs = Set<UInt64>()
    private var pendingFocusedMessageRequestID: UInt64?
    private var issuedFocusedMessageRequestIDs = Set<UInt64>()
    private var topicActionsByRequestID: [UInt64: TopicAction] = [:]
    private var messageActionsByRequestID: [UInt64: SubmittedMessageAction] = [:]
    private var failedMessageActions: [Int64: MessageAction] = [:]
    private var sendsByRequestID: [UInt64: PendingSend] = [:]
    private var failedSends: [Int64: PendingSend] = [:]
    private var knownTopics: [ConversationKey: LiveTopicSnapshot] = [:]

    init(
        client: any CoreClientProtocol = LiveCoreClient(),
        credentialStore: any CredentialStore = KeychainCredentialStore()
    ) {
        self.client = client
        self.credentialStore = credentialStore
    }

    func startObserving() {
        guard eventTask == nil else {
            return
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
            connectionState = .failed(message: "No saved API key was found for this account.")
        }
    }

    func openConversation(_ key: ConversationKey) {
        guard identity?.accountID == key.accountID else {
            return
        }
        pendingFocusedMessageRequestID = nil
        pendingOlderRequestID = nil
        isLoadingOlderMessages = false
        activeSelection = key
        let destination = navigationDirectory.destination(for: key)
        conversationState = .loading(
            title: destination?.title ?? "Conversation",
            subtitle: destination?.subtitle ?? organizationName
        )
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

    func disconnect() {
        client.submit(.disconnect(requestID: nextRequestID()))
    }

    private func consume(_ event: BridgeEvent) async {
        switch event {
        case let .sessionStarted(_, identity, credential, snapshot):
            self.identity = identity
            serverURL = identity.serverURL
            email = identity.email
            apply(snapshot)
            do {
                try await credentialStore.save(credential)
            } catch {
                notice = "Connected, but the API key could not be saved in Keychain."
            }
            connectionState = .connected
            let inbox = ConversationKey.inbox(accountID: identity.accountID)
            openConversation(inbox)

        case let .snapshotUpdated(accountID, snapshot):
            guard identity?.accountID == accountID else {
                return
            }
            apply(snapshot)
            connectionState = .connected
            if let activeSelection {
                refreshConversation(activeSelection)
            }

        case let .conversationOpened(_, page):
            guard pendingFocusedMessageRequestID == nil,
                  activeSelection == page.key
            else {
                return
            }
            rememberTopics(from: page.messages)
            let existing = loadedPage(for: page.key)
            conversationState = .loaded(
                makeConversationPage(page, merging: existing)
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

        case let .messageSent(requestID, _, _):
            if let send = sendsByRequestID.removeValue(forKey: requestID) {
                removeLoadedMessage(send.localMessageID)
            }
            if let activeSelection {
                refreshConversation(activeSelection)
            }

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

        case .messagesMarkedRead, .pong:
            break

        case let .retryScheduled(_, delayMilliseconds):
            connectionState = .retrying(delayMilliseconds: delayMilliseconds)

        case .disconnected:
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
            isLoadingOlderMessages = false
            messageSearchState = .idle
            topicActionState = .idle
            requestedTopicNavigation = nil
            knownTopics = [:]
            connectionState = .signedOut

        case let .failed(requestID, message):
            if let requestID, issuedSearchRequestIDs.remove(requestID) != nil {
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
            } else if pendingOlderRequestID == requestID {
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
            } else {
                connectionState = .failed(message: message)
            }
        }
    }

    private func apply(_ snapshot: LiveSnapshot) {
        guard let identity else {
            return
        }
        rememberTopics(from: snapshot.topics)
        rememberTopics(from: snapshot.messages)
        sidebarSnapshot = Self.makeSidebar(
            snapshot: snapshot,
            identity: identity,
            topics: Array(knownTopics.values)
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
        let messages = mergeMessages(existing?.messages ?? [], incoming)
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
                content: [.paragraph([.text(message.contentHTML)])],
                isOwnMessage: message.senderID == identity?.userID,
                sourceStreamID: message.streamID,
                sourceTopic: message.topic,
                isStarred: message.flags.contains("starred"),
                reactionCount: thumbsUp.count,
                hasOwnThumbsUp: thumbsUp.contains { $0.userID == identity?.userID },
                isRead: message.flags.contains("read")
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
            deliveryState: .pending
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
            contentPreview: result.message.contentHTML,
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
            currentUserInitials: sidebar.currentUserInitials
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

    private static func makeSidebar(
        snapshot: LiveSnapshot,
        identity: LiveSessionIdentity,
        topics: [LiveTopicSnapshot]
    ) -> SidebarSnapshot {
        let host = URL(string: identity.serverURL)?.host ?? identity.serverURL
        let organization = host.split(separator: ".").first
            .map { String($0).capitalized } ?? host
        let currentName = identity.fullName.isEmpty ? identity.email : identity.fullName
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
                    presence: .offline
                )
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
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
            currentUserInitials: initials(for: currentName)
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
