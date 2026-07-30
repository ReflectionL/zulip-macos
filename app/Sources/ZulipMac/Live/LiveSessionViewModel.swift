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
    var authenticationMethod = LiveAuthenticationMethod.password
    var serverURL = ""
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

    @ObservationIgnored private let client: any CoreClientProtocol
    @ObservationIgnored private let credentialStore: any CredentialStore
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    private var requestID: UInt64 = 1
    private var activeSelection: ConversationKey?

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
                limit: 100
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

        case let .conversationOpened(_, page):
            guard activeSelection == page.key else {
                return
            }
            conversationState = .loaded(makeConversationPage(page))
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

        case .messageSent:
            if let activeSelection {
                openConversation(activeSelection)
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
            connectionState = .signedOut

        case let .failed(_, message):
            connectionState = .failed(message: message)
        }
    }

    private func apply(_ snapshot: LiveSnapshot) {
        guard let identity else {
            return
        }
        let sidebar = Self.makeSidebar(snapshot: snapshot, identity: identity)
        sidebarSnapshot = sidebar
        navigationDirectory = Self.makeDirectory(
            snapshot: snapshot,
            sidebar: sidebar
        )
    }

    private func makeConversationPage(_ livePage: LiveConversationPage) -> ConversationPage {
        let destination = navigationDirectory.destination(for: livePage.key)
        return ConversationPage(
            key: livePage.key,
            title: destination?.title ?? "Conversation",
            subtitle: destination?.subtitle ?? organizationName,
            messages: livePage.messages.map { message in
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
            },
            beforeCursor: livePage.foundOldest ? nil : "older",
            afterCursor: livePage.foundNewest ? nil : "newer"
        )
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
                    && $0.userID != identity.userID
                    && $0.email?.caseInsensitiveCompare(identity.email) != .orderedSame
            }
            .map {
                DirectMessageSnapshot(
                    userID: $0.userID,
                    displayName: $0.fullName,
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
        snapshot: LiveSnapshot,
        sidebar: SidebarSnapshot
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
        let topics = snapshot.messages.compactMap { message -> NavigationDestination? in
            guard let streamID = message.streamID,
                  let topic = message.topic,
                  !topic.isEmpty
            else {
                return nil
            }
            let key = ConversationKey.topic(
                accountID: sidebar.accountID,
                streamID: streamID,
                topic: topic
            )
            guard seenTopics.insert(key).inserted else {
                return nil
            }
            let channel = channelNames[streamID] ?? "channel"
            return NavigationDestination(
                key: key,
                title: topic,
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
            destinations: quickLinks + channels + topics + directMessages
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
