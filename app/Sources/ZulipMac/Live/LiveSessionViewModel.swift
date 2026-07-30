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

@MainActor
@Observable
final class LiveSessionViewModel {
    static let defaultServerURL = "https://shitcreator.zulipchat.com"
    private static let conversationPageSize: UInt16 = 10

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

    @ObservationIgnored private let client: any CoreClientProtocol
    @ObservationIgnored private let credentialStore: any CredentialStore
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    private var requestID: UInt64 = 1
    private var activeSelection: ConversationKey?
    private var pendingOlderRequestID: UInt64?
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
            notice = "Choose a topic or direct message before sending."
            return false
        }
        return true
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
            guard activeSelection == page.key else {
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

        case .messageSent:
            if let activeSelection {
                refreshConversation(activeSelection)
            }

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
            isLoadingOlderMessages = false
            knownTopics = [:]
            connectionState = .signedOut

        case let .failed(requestID, message):
            if pendingOlderRequestID == requestID {
                pendingOlderRequestID = nil
                isLoadingOlderMessages = false
                notice = "Earlier messages could not be loaded: \(message)"
            } else {
                connectionState = .failed(message: message)
            }
        }
    }

    private func apply(_ snapshot: LiveSnapshot) {
        guard let identity else {
            return
        }
        let sidebar = Self.makeSidebar(snapshot: snapshot, identity: identity)
        sidebarSnapshot = sidebar
        rememberTopics(from: snapshot.topics)
        rememberTopics(from: snapshot.messages)
        navigationDirectory = Self.makeDirectory(
            sidebar: sidebar,
            topics: Array(knownTopics.values)
        )
    }

    private func makeConversationPage(
        _ livePage: LiveConversationPage,
        merging existing: ConversationPage? = nil
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
                : messages.last.map { String($0.id) }
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
            afterCursor: existing.afterCursor
        )
    }

    private func makeMessages(_ livePage: LiveConversationPage) -> [MessageViewData] {
        livePage.messages.map { message in
            MessageViewData(
                id: message.messageID,
                accountID: livePage.key.accountID,
                conversationKey: livePage.key,
                senderID: message.senderID,
                senderName: message.senderFullName,
                senderInitials: Self.initials(for: message.senderFullName),
                timestamp: message.timestamp,
                content: [.paragraph([.text(message.contentHTML)])],
                isOwnMessage: message.senderID == identity?.userID
            )
        }
    }

    private func mergeMessages(
        _ first: [MessageViewData],
        _ second: [MessageViewData]
    ) -> [MessageViewData] {
        var messagesByID = Dictionary(
            uniqueKeysWithValues: first.map { ($0.id, $0) }
        )
        for message in second {
            messagesByID[message.id] = message
        }
        return messagesByID.values.sorted { $0.id < $1.id }
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
        if let sidebarSnapshot {
            navigationDirectory = Self.makeDirectory(
                sidebar: sidebarSnapshot,
                topics: Array(knownTopics.values)
            )
        }
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

    private static func makeSidebar(
        snapshot: LiveSnapshot,
        identity: LiveSessionIdentity
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
            channels: snapshot.channels.map {
                ChannelSnapshot(
                    streamID: $0.streamID,
                    name: $0.name,
                    colorHex: $0.colorHex,
                    isMuted: $0.isMuted
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
