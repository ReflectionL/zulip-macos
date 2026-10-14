import Foundation
import SwiftUI
import Testing
import ZulipCoreBindings
@testable import ZulipMac

@Suite("Live session presentation")
@MainActor
struct LiveSessionTests {
    @Test("Login does not assume a particular organization")
    func defaultServer() {
        let model = LiveSessionViewModel(
            client: RecordingCoreClient(),
            credentialStore: MemoryCredentialStore()
        )

        #expect(model.serverURL.isEmpty)
        #expect(model.email.isEmpty)
        #expect(model.secret.isEmpty)
    }

    @Test("The native login sheet renders without exposing a credential")
    func loginSheetRenders() {
        let model = LiveSessionViewModel(
            client: RecordingCoreClient(),
            credentialStore: MemoryCredentialStore()
        )
        model.serverURL = "https://acme.zulipchat.com"
        model.email = "maya@example.com"
        model.secret = "render-only-secret"

        let renderer = ImageRenderer(
            content: LiveLoginView(session: model)
                .frame(width: 520, height: 420)
        )
        renderer.scale = 1

        #expect(renderer.nsImage != nil)
        #expect(model.secret == "render-only-secret")
    }

    @Test("Password login is redacted, persisted as an API key, and opens Mentions")
    func passwordLogin() async throws {
        let core = RecordingCoreClient()
        let credentials = MemoryCredentialStore()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: credentials
        )
        model.serverURL = "https://acme.zulipchat.com/"
        model.email = "maya@example.com"
        model.secret = "password-that-must-not-leak"
        model.authenticationMethod = .password

        model.connect()

        let command = try #require(core.commands.first)
        guard case let .startPasswordSession(
            requestID,
            accountID,
            serverURL,
            username,
            password
        ) = command else {
            Issue.record("Expected password session command")
            return
        }
        #expect(requestID == 1)
        #expect(accountID == "https://acme.zulipchat.com|maya@example.com")
        #expect(serverURL == "https://acme.zulipchat.com/")
        #expect(username == "maya@example.com")
        #expect(password == "password-that-must-not-leak")
        #expect(model.secret.isEmpty)
        #expect(!String(describing: command).contains(password))
        #expect(!String(reflecting: command).contains(password))

        core.emit(
            .sessionStarted(
                requestID: requestID,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(
                    accountID: accountID,
                    apiKey: "derived-api-key"
                ),
                snapshot: snapshot
            )
        )
        await eventually {
            model.connectionState == .connected
                && core.commands.contains {
                    if case let .openConversation(_, key, _) = $0 {
                        return key == .mentions(accountID: accountID)
                    }
                    return false
                }
        }

        #expect(model.sidebarSnapshot?.channels.map(\.name) == ["engineering"])
        #expect(model.sidebarSnapshot?.currentUserName == "Maya Chen")
        #expect(
            model.sidebarSnapshot?.quickLinks.map(\.title)
                == ["Mentions", "Starred"]
        )
        #expect(
            model.navigationDirectory
                .destination(
                    for: .topic(
                        accountID: accountID,
                        streamID: 5,
                        topic: "macOS"
                    )
                )?
                .title == "macOS"
        )
        let savedCredential = await credentials.savedCredential()
        #expect(
            savedCredential
                == StoredAPICredential(accountID: accountID, apiKey: "derived-api-key")
        )
    }

    @Test("A relaunch restores the last account from its saved API key")
    func restoresSavedSession() async throws {
        let accountID = "https://acme.zulipchat.com|maya@example.com"
        let defaults = try #require(UserDefaults(suiteName: "restore-\(UUID().uuidString)"))
        let credentials = MemoryCredentialStore()

        let firstCore = RecordingCoreClient()
        let signedIn = LiveSessionViewModel(
            client: firstCore,
            credentialStore: credentials,
            defaults: defaults
        )
        signedIn.startObserving()
        firstCore.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "saved-key"),
                snapshot: snapshot
            )
        )
        await eventually { signedIn.connectionState == .connected }

        let relaunchCore = RecordingCoreClient()
        let relaunched = LiveSessionViewModel(
            client: relaunchCore,
            credentialStore: credentials,
            defaults: defaults
        )
        await relaunched.restoreSavedSession()

        guard case let .loadCachedSession(_, cachedAccountID) = try #require(
            relaunchCore.commands.first
        ) else {
            Issue.record("Expected the cached session to load first")
            return
        }
        #expect(cachedAccountID == accountID)
        let command = try #require(relaunchCore.commands.dropFirst().first)
        guard case let .startAPIKeySession(_, restoredAccountID, _, restoredEmail, apiKey) = command
        else {
            Issue.record("Expected an API-key session command")
            return
        }
        #expect(restoredAccountID == accountID)
        #expect(restoredEmail == "maya@example.com")
        #expect(apiKey == "saved-key")
        #expect(relaunched.connectionState == .connecting)
    }

    @Test("Restoring without a remembered account or key stays quietly signed out")
    func restoreWithoutAccountOrKey() async throws {
        let defaults = try #require(UserDefaults(suiteName: "restore-\(UUID().uuidString)"))
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore(),
            defaults: defaults
        )
        await model.restoreSavedSession()
        #expect(core.commands.isEmpty)
        #expect(model.connectionState == .signedOut)

        defaults.set("https://acme.zulipchat.com", forKey: "lastAccount.serverURL")
        defaults.set("maya@example.com", forKey: "lastAccount.email")
        await model.restoreSavedSession()
        #expect(!core.commands.contains(where: isAPIKeyStart))
        #expect(model.connectionState == .signedOut)
    }

    @Test("An explicit disconnect is not undone by the next launch")
    func disconnectForgetsLastAccount() async throws {
        let accountID = "https://acme.zulipchat.com|maya@example.com"
        let defaults = try #require(UserDefaults(suiteName: "restore-\(UUID().uuidString)"))
        let core = RecordingCoreClient()
        let credentials = MemoryCredentialStore()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: credentials,
            defaults: defaults
        )
        model.startObserving()
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "saved-key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        core.emit(.disconnected(requestID: 2))
        await eventually { model.connectionState == .signedOut }

        let relaunchCore = RecordingCoreClient()
        let relaunched = LiveSessionViewModel(
            client: relaunchCore,
            credentialStore: credentials,
            defaults: defaults
        )
        await relaunched.restoreSavedSession()
        #expect(relaunchCore.commands.isEmpty)
    }

    @Test("A core-ended session returns to sign-in and drops the rejected key")
    func coreEndedSessionIsReported() async {
        let core = RecordingCoreClient()
        let credentials = MemoryCredentialStore()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: credentials
        )
        model.startObserving()
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: "account-1"),
                credential: StoredAPICredential(accountID: "account-1", apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }
        #expect(await credentials.savedCredential() != nil)

        core.emit(.failed(requestID: nil, message: "sign in again"))
        await eventually { model.connectionState == .failed(message: "sign in again") }

        #expect(model.identity == nil)
        #expect(model.sidebarSnapshot == nil)
        #expect(model.notice?.contains("Earlier messages") != true)
        await eventually { await credentials.savedCredential() == nil }
    }

    @Test("Retry state clears once polling succeeds again")
    func retryingClearsWhenSyncResumes() async {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore()
        )
        model.startObserving()
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: "account-1"),
                credential: StoredAPICredential(accountID: "account-1", apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        core.emit(.retryScheduled(accountID: "account-1", delayMilliseconds: 1_000))
        await eventually { model.connectionState == .retrying(delayMilliseconds: 1_000) }

        core.emit(.syncResumed(accountID: "account-1"))
        await eventually { model.connectionState == .connected }
    }

    @Test("Read receipts list the readers of the latest sent message and stop when unsupported")
    func readReceipts() async {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore()
        )
        model.isApplicationActive = { true }
        model.startObserving()
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: "account-1"),
                credential: StoredAPICredential(accountID: "account-1", apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        let key = ConversationKey.directMessage(accountID: "account-1", recipientIDs: [22])
        func page(ownMessageID: Int64) -> ConversationPage {
            ConversationPage(
                key: key,
                title: "Theo Martin",
                subtitle: "",
                messages: [
                    MessageViewData(
                        id: ownMessageID,
                        accountID: "account-1",
                        conversationKey: key,
                        senderID: 9,
                        senderName: "Maya Chen",
                        senderInitials: "MC",
                        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                        content: [],
                        isOwnMessage: true
                    ),
                ]
            )
        }
        func receiptRequests() -> Int {
            core.commands.filter {
                if case .fetchReadReceipts = $0 { return true }
                return false
            }.count
        }

        #expect(model.readReceiptDisplay(for: page(ownMessageID: 70))?.messageID == 70)
        #expect(model.readReceiptDisplay(for: page(ownMessageID: 70))?.readers.isEmpty == true)

        #expect(model.pollReadReceipts(messageID: 70, key: key))
        #expect(receiptRequests() == 1)
        // Asking again right away is throttled but polling carries on.
        #expect(model.pollReadReceipts(messageID: 70, key: key))
        #expect(receiptRequests() == 1)

        // Your own id and people the client does not know are left out.
        core.emit(
            .readReceiptsLoaded(
                accountID: "account-1",
                messageID: 70,
                userIDs: [9, 22, 99],
                isAvailable: true
            )
        )
        await eventually {
            model.readReceiptDisplay(for: page(ownMessageID: 70))?.readers.map(\.userID) == [22]
        }
        #expect(
            model.readReceiptDisplay(for: page(ownMessageID: 70))?.readers.first?.name
                == "Theo Martin"
        )
        // Everyone in the direct message has read it, so there is nothing left to ask.
        #expect(!model.pollReadReceipts(messageID: 70, key: key))

        // Two messages in a row the server cannot report: stop for the session.
        core.emit(
            .readReceiptsLoaded(accountID: "account-1", messageID: 71, userIDs: [], isAvailable: false)
        )
        core.emit(
            .readReceiptsLoaded(accountID: "account-1", messageID: 72, userIDs: [], isAvailable: false)
        )
        await eventually { model.readReceiptDisplay(for: page(ownMessageID: 73)) == nil }
        #expect(!model.pollReadReceipts(messageID: 73, key: key))
    }

    @Test("A cached session is shown first and survives an offline start")
    func cachedSessionSurvivesOfflineStart() async throws {
        let accountID = "https://acme.zulipchat.com|maya@example.com"
        let defaults = try #require(UserDefaults(suiteName: "restore-\(UUID().uuidString)"))
        defaults.set("https://acme.zulipchat.com", forKey: "lastAccount.serverURL")
        defaults.set("maya@example.com", forKey: "lastAccount.email")
        let credentials = MemoryCredentialStore()
        await credentials.save(StoredAPICredential(accountID: accountID, apiKey: "saved-key"))
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: credentials,
            defaults: defaults
        )
        await model.restoreSavedSession()
        let cachedRequestID = try #require(core.commands.first?.requestID)
        let startRequestID = try #require(core.commands.dropFirst().first?.requestID)

        core.emit(
            .cachedSessionLoaded(
                requestID: cachedRequestID,
                identity: identity(accountID: accountID),
                snapshot: snapshot
            )
        )
        await eventually { model.identity != nil }
        #expect(model.sidebarSnapshot?.channels.map(\.name) == ["engineering"])
        #expect(model.sidebarSnapshot?.organizationIconURL == "/user_avatars/2/realm/icon.png")
        #expect(model.sidebarSnapshot?.currentUserAvatarURL == "/user_avatars/2/maya.png")
        #expect(
            model.sidebarSnapshot?.directMessages.first { $0.userID == 22 }?.avatarURL
                == "https://cdn.example.com/theo.png"
        )

        func presence(of userID: Int64) -> PresenceState? {
            model.sidebarSnapshot?.directMessages.first { $0.userID == userID }?.presence
        }
        #expect(presence(of: 22) == .offline)
        core.emit(
            .presenceUpdated(
                accountID: accountID,
                presences: [
                    LivePresence(userID: 22, state: .active),
                    LivePresence(userID: 9, state: .idle),
                ]
            )
        )
        await eventually { presence(of: 22) == .active }
        #expect(presence(of: 9) == .idle)
        #expect(model.presenceDescription(forUserID: 22) == "Active now")
        #expect(
            model.presenceDescription(for: .directMessage(accountID: accountID, recipientIDs: [22]))
                == "Active now"
        )
        // Your own row and group conversations have no status.
        #expect(model.presenceDescription(forUserID: 9) == nil)
        #expect(
            model.presenceDescription(for: .directMessage(accountID: accountID, recipientIDs: [22, 23]))
                == nil
        )

        core.emit(
            .conversationOpened(
                requestID: 99,
                page: LiveConversationPage(
                    key: .mentions(accountID: accountID),
                    messages: [
                        LiveMessageSnapshot(
                            messageID: 44,
                            senderID: 22,
                            senderFullName: "Theo Martin",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                            content: [.paragraph([.text("Cached hello")])],
                            streamID: 5,
                            topic: "macOS",
                            recipientIDs: []
                        ),
                    ],
                    foundOldest: true,
                    foundNewest: true
                )
            )
        )
        await eventually {
            if case let .offline(page) = model.conversationState {
                return page.messages.first?.plainText == "Cached hello"
                    && page.messages.first?.senderAvatarURL == "https://cdn.example.com/theo.png"
            }
            return false
        }
        #expect(!core.commands.contains {
            if case .markRead = $0 { return true }
            return false
        })

        core.emit(
            .failed(
                requestID: startRequestID,
                message: "could not connect securely to the Zulip server: offline"
            )
        )
        await eventually {
            if case .retrying = model.connectionState { return true }
            return false
        }
        #expect(model.identity != nil)

        func sessionStarts() -> Int {
            core.commands.filter {
                if case .startAPIKeySession = $0 { return true }
                return false
            }.count
        }
        let before = sessionStarts()
        model.handleSystemWake()
        await eventually { sessionStarts() == before + 1 }
    }

    @Test("A missing cache on first launch does not interrupt the live connection")
    func missingCacheIsQuiet() async throws {
        let defaults = try #require(UserDefaults(suiteName: "restore-\(UUID().uuidString)"))
        defaults.set("https://acme.zulipchat.com", forKey: "lastAccount.serverURL")
        defaults.set("maya@example.com", forKey: "lastAccount.email")
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore(),
            defaults: defaults
        )
        await model.restoreSavedSession()
        let cachedRequestID = try #require(core.commands.first?.requestID)

        core.emit(.failed(requestID: cachedRequestID, message: "no cached data"))
        for _ in 0..<20 { await Task.yield() }
        #expect(model.connectionState == .signedOut)
    }

    @Test("Transient failures are told apart from rejected credentials")
    func transientFailureClassification() {
        #expect(LiveSessionViewModel.isTransientFailure(
            "could not connect securely to the Zulip server: timed out"
        ))
        #expect(LiveSessionViewModel.isTransientFailure(
            "could not synchronize with the Zulip server: reset"
        ))
        #expect(LiveSessionViewModel.isTransientFailure("authentication returned HTTP 503"))
        #expect(!LiveSessionViewModel.isTransientFailure(
            "the username, password, or API key was not accepted"
        ))
    }

    @Test("Composer drafts are remembered, persisted after a pause, and restored")
    func draftsPersist() async throws {
        let accountID = "https://acme.zulipchat.com|maya@example.com"
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore(),
            defaults: try #require(UserDefaults(suiteName: "drafts-\(UUID().uuidString)"))
        )
        model.startObserving()
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }
        #expect(core.commands.contains {
            if case .loadDrafts = $0 { return true }
            return false
        })

        let key = ConversationKey.channel(accountID: accountID, streamID: 5)
        model.updateDraft("half-writ", for: key)
        model.updateDraft("half-written", for: key)
        #expect(model.draft(for: key) == "half-written")

        try await Task.sleep(for: .milliseconds(900))
        let saves = core.commands.compactMap { command -> String? in
            if case let .saveDraft(_, savedKey, content) = command, savedKey == key {
                return content
            }
            return nil
        }
        #expect(saves == ["half-written"], "typing is debounced into one write")

        let other = ConversationKey.inbox(accountID: accountID)
        core.emit(
            .draftsLoaded(
                requestID: 7,
                accountID: accountID,
                drafts: [
                    LiveDraft(key: key, content: "stale stored text"),
                    LiveDraft(key: other, content: "from last launch"),
                ]
            )
        )
        await eventually { model.draft(for: other) == "from last launch" }
        #expect(model.draft(for: key) == "half-written")

        model.updateDraft("", for: key)
        #expect(model.draft(for: key).isEmpty)
    }

    @Test("Direct messages are ordered by who wrote or was written to most recently")
    func directMessageRecency() {
        func direct(_ id: Int64, sender: Int64, recipients: [Int64]) -> LiveMessageSnapshot {
            LiveMessageSnapshot(
                messageID: id,
                senderID: sender,
                senderFullName: "Sender",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                content: [],
                streamID: nil,
                topic: nil,
                recipientIDs: recipients
            )
        }
        let stream = LiveMessageSnapshot(
            messageID: 99,
            senderID: 30,
            senderFullName: "Sender",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            content: [],
            streamID: 5,
            topic: "macOS",
            recipientIDs: []
        )
        let recency = LiveSessionViewModel.directMessageRecency(
            in: [
                direct(10, sender: 22, recipients: [9, 22]),
                direct(12, sender: 9, recipients: [30]),
                direct(11, sender: 22, recipients: [9]),
                direct(13, sender: 22, recipients: [9, 22, 30]),
                stream,
            ],
            currentUserID: 9
        )
        #expect(recency == [22: 11, 30: 12])
    }

    @Test("Server recent conversations seed direct message order and live messages raise it")
    func directMessageRecencyUsesServerConversations() {
        let live = LiveMessageSnapshot(
            messageID: 500,
            senderID: 22,
            senderFullName: "Sender",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            content: [],
            streamID: nil,
            topic: nil,
            recipientIDs: [9, 22]
        )
        let recency = LiveSessionViewModel.directMessageRecency(
            in: [live],
            currentUserID: 9,
            serverConversations: [
                LiveRecentDirectConversation(userIDs: [22, 9], maxMessageID: 300),
                LiveRecentDirectConversation(userIDs: [30], maxMessageID: 400),
                LiveRecentDirectConversation(userIDs: [9], maxMessageID: 50),
                LiveRecentDirectConversation(userIDs: [22, 30, 9], maxMessageID: 900),
            ]
        )
        #expect(recency == [22: 500, 30: 400, 9: 50])
    }

    @Test("Opening a conversation shows its cached copy until the fresh page replaces it")
    func cachedConversationShownFirst() async {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(client: core, credentialStore: MemoryCredentialStore())
        model.startObserving()
        let accountID = "account-1"
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        let key = ConversationKey.topic(accountID: accountID, streamID: 5, topic: "macOS")
        model.openConversation(key)
        let commands = core.commands.suffix(2)
        guard case .loadCachedConversation = commands.first,
              case .openConversation = commands.last
        else {
            Issue.record("Expected the cache read to be submitted before the fetch")
            return
        }
        func page(_ messageID: Int64, _ text: String) -> LiveConversationPage {
            LiveConversationPage(
                key: key,
                messages: [
                    LiveMessageSnapshot(
                        messageID: messageID,
                        senderID: 22,
                        senderFullName: "Theo Martin",
                        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                        content: [.paragraph([.text(text)])],
                        streamID: 5,
                        topic: "macOS",
                        recipientIDs: []
                    ),
                ],
                foundOldest: true,
                foundNewest: true
            )
        }

        core.emit(.cachedConversationLoaded(requestID: 2, page: page(40, "Cached")))
        await eventually {
            if case let .loaded(shown) = model.conversationState {
                return shown.messages.map(\.plainText) == ["Cached"]
            }
            return false
        }
        #expect(!core.commands.contains {
            if case .markRead = $0 { return true }
            return false
        })

        core.emit(.conversationOpened(requestID: 3, page: page(41, "Fresh")))
        await eventually {
            if case let .loaded(shown) = model.conversationState {
                return shown.messages.map(\.plainText) == ["Fresh"]
            }
            return false
        }

        // A cache answer that arrives after the fresh page must not roll it back.
        core.emit(.cachedConversationLoaded(requestID: 2, page: page(40, "Cached")))
        for _ in 0..<30 { await Task.yield() }
        if case let .loaded(shown) = model.conversationState {
            #expect(shown.messages.map(\.plainText) == ["Fresh"])
        } else {
            Issue.record("Expected the fresh page to stay loaded")
        }
    }

    @Test("Quoting fetches the source and inserts a quote; forwarding posts it elsewhere")
    func quoteAndForward() async {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(client: core, credentialStore: MemoryCredentialStore())
        model.startObserving()
        let accountID = "account-1"
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        let key = ConversationKey.topic(accountID: accountID, streamID: 5, topic: "macOS")
        model.openConversation(key)
        core.emit(
            .conversationOpened(
                requestID: 2,
                page: LiveConversationPage(
                    key: key,
                    messages: [
                        LiveMessageSnapshot(
                            messageID: 40,
                            senderID: 22,
                            senderFullName: "Theo Martin",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                            content: [.paragraph([.text("Rendered")])],
                            streamID: 5,
                            topic: "macOS",
                            recipientIDs: []
                        ),
                    ],
                    foundOldest: true,
                    foundNewest: true
                )
            )
        )
        await eventually {
            if case .loaded = model.conversationState { return true }
            return false
        }
        guard case let .loaded(page) = model.conversationState,
              let message = page.messages.first
        else {
            Issue.record("Expected a loaded message")
            return
        }

        model.quote(message)
        guard case let .fetchMessageSource(quoteID, _, 40) = core.commands.last else {
            Issue.record("Expected the message source to be requested")
            return
        }
        core.emit(.messageSourceLoaded(requestID: quoteID, messageID: 40, content: "**raw**"))
        await eventually { model.attachmentInsertion != nil }
        let insertion = model.attachmentInsertion
        #expect(insertion?.key == key)
        #expect(insertion?.markdown.contains("@_**Theo Martin|22**") == true)
        #expect(insertion?.quote?.senderName == "Theo Martin")
        #expect(insertion?.quote?.snippet == "Rendered")
        #expect(insertion?.markdown.contains("```quote\n**raw**\n```") == true)

        let other = ConversationKey.topic(accountID: accountID, streamID: 5, topic: "other")
        model.forward(message, to: other)
        guard case let .fetchMessageSource(forwardID, _, 40) = core.commands.last else {
            Issue.record("Expected a second source request")
            return
        }
        core.emit(.messageSourceLoaded(requestID: forwardID, messageID: 40, content: "**raw**"))
        await eventually {
            if case let .sendChannelMessage(_, _, 5, "other", content, _) = core.commands.last {
                return content.contains("**raw**")
            }
            return false
        }
    }

    @Test("Mentions offer other people, and a new channel subscribes the user too")
    func mentionsAndChannelCreation() async {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(client: core, credentialStore: MemoryCredentialStore())
        model.startObserving()
        let accountID = "account-1"
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        let topicKey = ConversationKey.topic(accountID: accountID, streamID: 5, topic: "macOS")
        let inTopic = model.mentionCandidates(for: topicKey)
        #expect(inTopic.map(\.name) == ["all", "topic", "Theo Martin"])
        let inDirect = model.mentionCandidates(
            for: .directMessage(accountID: accountID, recipientIDs: [22])
        )
        #expect(inDirect.map(\.name) == ["Theo Martin"])
        #expect(model.channelMemberCandidates.map(\.name) == ["Theo Martin"])

        model.createChannel(name: "engineering", description: "", isPrivate: false, memberIDs: [])
        if case .failed = model.channelCreationState {} else {
            Issue.record("An existing channel name must be refused before any request")
        }

        model.createChannel(name: " design ", description: "Visuals", isPrivate: true, memberIDs: [22, 22])
        guard case let .createChannel(requestID, _, "design", "Visuals", true, members) = core.commands.last
        else {
            Issue.record("Expected a create-channel command")
            return
        }
        #expect(members == [9, 22])
        core.emit(.channelCreated(requestID: requestID, name: "design"))
        await eventually { model.channelCreationState == .created(name: "design") }
    }

    @Test("Writing in a channel sends to its general chat and holds Markdown back as a placeholder")
    func channelSendGoesToGeneralChat() async {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(client: core, credentialStore: MemoryCredentialStore())
        model.startObserving()
        let accountID = "account-1"
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        let key = ConversationKey.channel(accountID: accountID, streamID: 5)
        model.openConversation(key)
        core.emit(
            .conversationOpened(
                requestID: 3,
                page: LiveConversationPage(
                    key: key,
                    messages: [
                        LiveMessageSnapshot(
                            messageID: 44,
                            senderID: 22,
                            senderFullName: "Theo Martin",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                            content: [.paragraph([.text("Hello")])],
                            streamID: 5,
                            topic: "macOS",
                            recipientIDs: []
                        ),
                    ],
                    foundOldest: true,
                    foundNewest: true
                )
            )
        )
        await eventually {
            if case let .loaded(page) = model.conversationState {
                return page.messages.count == 1
            }
            return false
        }

        #expect(model.sendText("Plain words", to: key))
        guard case let .sendChannelMessage(_, _, streamID, topic, content, _) = core.commands.last
        else {
            Issue.record("Expected a channel message command")
            return
        }
        #expect(streamID == 5)
        #expect(topic.isEmpty)
        #expect(content == "Plain words")

        #expect(model.sendText("# Title\n\nSome **body**", to: key))
        guard case let .loaded(page) = model.conversationState else {
            Issue.record("Expected a loaded conversation")
            return
        }
        #expect(page.messages.map(\.isProvisional) == [false, false, true])
        #expect(page.messages.last?.sourceTopic == "")
    }

    @Test("A channel rename is validated, sent once, and reported back")
    func renameChannel() async {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(client: core, credentialStore: MemoryCredentialStore())
        model.startObserving()
        let accountID = "account-1"
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        model.renameChannel(streamID: 5, to: "engineering")
        if case .failed = model.channelRenameState {} else {
            Issue.record("The current name must be refused before any request")
        }
        model.renameChannel(streamID: 5, to: "   ")
        if case .failed = model.channelRenameState {} else {
            Issue.record("A blank name must be refused before any request")
        }

        model.renameChannel(streamID: 5, to: " platform ")
        guard case let .renameChannel(requestID, commandAccountID, 5, "platform") = core.commands.last
        else {
            Issue.record("Expected a rename-channel command")
            return
        }
        #expect(commandAccountID == accountID)
        #expect(model.channelRenameState == .renaming)
        core.emit(.failed(requestID: requestID, message: "Insufficient permission"))
        await eventually {
            model.channelRenameState == .failed(message: "Insufficient permission")
        }

        model.renameChannel(streamID: 5, to: "platform")
        guard case let .renameChannel(secondRequestID, _, _, _) = core.commands.last else {
            Issue.record("Expected a second rename-channel command")
            return
        }
        core.emit(.channelRenamed(requestID: secondRequestID, streamID: 5, name: "platform"))
        await eventually { model.channelRenameState == .renamed(name: "platform") }
    }

    @Test("Notification settings are written to Zulip and a refusal is reported quietly")
    func notificationSettings() async {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(client: core, credentialStore: MemoryCredentialStore())
        model.startObserving()
        let accountID = "account-1"
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        model.setChannelNotifications(streamID: 5, enabled: true)
        guard case let .setNotificationSetting(requestID, commandAccountID, 5, true) = core.commands.last
        else {
            Issue.record("Expected a channel notification command")
            return
        }
        #expect(commandAccountID == accountID)
        core.emit(.failed(requestID: requestID, message: "not allowed"))
        await eventually { model.notice?.contains("not allowed") == true }
        #expect(model.connectionState == .connected, "a refused setting is not a connection failure")

        model.setChannelNotificationsDefault(true)
        guard case let .setNotificationSetting(secondRequestID, _, nil, true) = core.commands.last else {
            Issue.record("Expected an account default notification command")
            return
        }
        core.emit(.notificationSettingSaved(requestID: secondRequestID))
        #expect(model.connectionState == .connected)
    }

    @Test("A conversation whose first page cannot be fetched offers a retry instead of loading forever")
    func failedFirstPageShowsFailure() async {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(client: core, credentialStore: MemoryCredentialStore())
        model.startObserving()
        let accountID = "account-1"
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        model.openConversation(.channel(accountID: accountID, streamID: 5))
        guard case let .openConversation(requestID, _, _) = core.commands.last else {
            Issue.record("Expected an open-conversation command")
            return
        }
        core.emit(.failed(requestID: requestID, message: "could not communicate with the Zulip server"))
        await eventually {
            if case .failure = model.conversationState { return true }
            return false
        }
        #expect(model.connectionState == .connected, "a failed page is not a lost connection")

        model.retryOpenConversation()
        if case .openConversation = core.commands.last {} else {
            Issue.record("Retrying must ask for the page again")
        }
        if case .loading = model.conversationState {} else {
            Issue.record("Retrying shows the loading state again")
        }
    }

    @Test("Reopening a conversation seen this session paints at once without a loading state")
    func reopenedConversationSkipsLoading() async {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(client: core, credentialStore: MemoryCredentialStore())
        model.startObserving()
        let accountID = "account-1"
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        let first = ConversationKey.topic(accountID: accountID, streamID: 5, topic: "macOS")
        let second = ConversationKey.topic(accountID: accountID, streamID: 5, topic: "release")
        func page(_ key: ConversationKey, topic: String, _ text: String) -> LiveConversationPage {
            LiveConversationPage(
                key: key,
                messages: [
                    LiveMessageSnapshot(
                        messageID: 40,
                        senderID: 22,
                        senderFullName: "Theo Martin",
                        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                        content: [.paragraph([.text(text)])],
                        streamID: 5,
                        topic: topic,
                        recipientIDs: []
                    ),
                ],
                foundOldest: true,
                foundNewest: true
            )
        }

        model.openConversation(first)
        core.emit(.conversationOpened(requestID: 2, page: page(first, topic: "macOS", "Hello")))
        await eventually {
            if case .loaded = model.conversationState { return true }
            return false
        }
        model.openConversation(second)
        if case .loading = model.conversationState {} else {
            Issue.record("A never-opened conversation still waits for its first page")
        }

        // Going back to the first one shows its earlier content in the same turn.
        model.openConversation(first)
        guard case let .loaded(shown) = model.conversationState else {
            Issue.record("Expected the remembered page to be shown immediately")
            return
        }
        #expect(shown.messages.map(\.plainText) == ["Hello"])
    }

    @Test("Unread counts reach the sidebar, Mentions and the topic rows")
    func unreadCountsInSidebar() async {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore()
        )
        model.startObserving()
        let accountID = "account-1"
        let base = snapshot
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: LiveSnapshot(
                    revision: base.revision,
                    lastEventID: base.lastEventID,
                    users: base.users,
                    channels: base.channels,
                    topics: base.topics,
                    messages: base.messages,
                    unread: [
                        LiveUnreadBucket(streamID: 5, topic: "macOS", count: 3, mentionCount: 1),
                        LiveUnreadBucket(streamID: 5, topic: "design", count: 2),
                        LiveUnreadBucket(userIDs: [9, 22], count: 4),
                    ]
                )
            )
        )
        await eventually { model.sidebarSnapshot != nil }

        let sidebar = model.sidebarSnapshot
        #expect(sidebar?.channels.first?.unreadCount == 5)
        #expect(sidebar?.channels.first?.topics.first { $0.name == "macOS" }?.unreadCount == 3)
        #expect(sidebar?.directMessages.first { $0.userID == 22 }?.unreadCount == 4)
        #expect(sidebar?.quickLinks.first { $0.title == "Mentions" }?.unreadCount == 1)
    }

    @Test("Nothing is marked read while the app is in the background or from a collection")
    func doesNotReadWhileAway() async {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore()
        )
        model.startObserving()
        let accountID = "account-1"
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        let key = ConversationKey.topic(accountID: accountID, streamID: 5, topic: "macOS")
        model.openConversation(key)
        let message = LiveMessageSnapshot(
            messageID: 44,
            senderID: 22,
            senderFullName: "Theo Martin",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            content: [.paragraph([.text("Hello")])],
            streamID: 5,
            topic: "macOS",
            recipientIDs: []
        )
        model.isApplicationActive = { false }
        core.emit(
            .conversationOpened(
                requestID: 3,
                page: LiveConversationPage(
                    key: key,
                    messages: [message],
                    foundOldest: true,
                    foundNewest: true
                )
            )
        )
        await eventually {
            if case .loaded = model.conversationState { return true }
            return false
        }
        #expect(!core.commands.contains {
            if case .markRead = $0 { return true }
            return false
        })

        // Collections list messages out of context; opening one never reads them.
        #expect(LiveSessionViewModel.marksMessagesRead(in: key))
        #expect(!LiveSessionViewModel.marksMessagesRead(in: .mentions(accountID: accountID)))
        #expect(!LiveSessionViewModel.marksMessagesRead(in: .starred(accountID: accountID)))
    }

    @Test("A loaded conversation is mapped safely and marked read")
    func openConversation() async {
        let core = RecordingCoreClient()
        let credentials = MemoryCredentialStore()
        let model = LiveSessionViewModel(client: core, credentialStore: credentials)
        model.isApplicationActive = { true }
        model.startObserving()
        let accountID = "account-1"

        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        let key = ConversationKey.topic(
            accountID: accountID,
            streamID: 5,
            topic: "macOS"
        )
        model.openConversation(key)
        core.emit(
            .conversationOpened(
                requestID: 3,
                page: LiveConversationPage(
                    key: key,
                    messages: [
                        LiveMessageSnapshot(
                            messageID: 44,
                            senderID: 22,
                            senderFullName: "Theo Martin",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                            content: [.paragraph([.text("Hello "), .text("world")])],
                            streamID: 5,
                            topic: "macOS",
                            recipientIDs: []
                        ),
                    ],
                    foundOldest: false,
                    foundNewest: true
                )
            )
        )
        await eventually {
            if case let .loaded(page) = model.conversationState {
                return page.messages.first?.plainText == "Hello world"
            }
            return false
        }

        #expect(
            core.commands.contains {
                if case let .markRead(_, commandAccountID, messageIDs) = $0 {
                    return commandAccountID == accountID && messageIDs == [44]
                }
                return false
            }
        )
        #expect(model.sendText("A reply", to: key))
        let sendCommand = core.commands.last {
            if case .sendChannelMessage = $0 { return true }
            return false
        }
        guard case let .sendChannelMessage(
            sendRequestID,
            commandAccountID,
            streamID,
            topic,
            content,
            localID
        ) = sendCommand else {
            Issue.record("Expected send command")
            return
        }
        #expect(commandAccountID == accountID)
        #expect(streamID == 5)
        #expect(topic == "macOS")
        #expect(content == "A reply")
        let refreshCountBeforeSendCompletion = core.commands.filter {
            if case .openConversation = $0 { true } else { false }
        }.count
        core.emit(
            .messageSent(
                requestID: sendRequestID,
                localID: localID,
                messageID: 45
            )
        )
        await eventually {
            guard case let .loaded(page) = model.conversationState else { return false }
            let refreshCount = core.commands.filter {
                if case .openConversation = $0 { true } else { false }
            }.count
            return page.messages.allSatisfy { $0.deliveryState == .sent }
                && refreshCount > refreshCountBeforeSendCompletion
        }
        // The echo stays on screen until the server's rendered copy arrives, so
        // the sent message never disappears and reappears.
        if case let .loaded(page) = model.conversationState {
            #expect(page.messages.map(\.id).filter { $0 > 0 } == [44])
            #expect(page.messages.contains { $0.id < 0 })
        }
        core.emit(
            .conversationOpened(
                requestID: 90,
                page: LiveConversationPage(
                    key: key,
                    messages: [
                        LiveMessageSnapshot(
                            messageID: 44,
                            senderID: 22,
                            senderFullName: "Theo Martin",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                            content: [.paragraph([.text("Hello world")])],
                            streamID: 5,
                            topic: "macOS",
                            recipientIDs: []
                        ),
                        LiveMessageSnapshot(
                            messageID: 45,
                            senderID: 21,
                            senderFullName: "Maya Chen",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
                            content: [.paragraph([.text("A reply")])],
                            streamID: 5,
                            topic: "macOS",
                            recipientIDs: []
                        ),
                    ],
                    foundOldest: false,
                    foundNewest: true
                )
            )
        )
        await eventually {
            guard case let .loaded(page) = model.conversationState else { return false }
            return page.messages.map(\.id) == [44, 45]
        }
        // The server copy takes over the echo's row, so the row updates in place.
        if case let .loaded(page) = model.conversationState {
            #expect(page.messages.map(\.rowID) == [44, -Int64(sendRequestID)])
        }

        model.loadOlderMessages(for: key)
        let historyCommand = core.commands.last {
            if case .loadOlderMessages = $0 {
                return true
            }
            return false
        }
        guard case let .loadOlderMessages(
            historyRequestID,
            historyKey,
            beforeMessageID,
            limit
        ) = historyCommand else {
            Issue.record("Expected history command")
            return
        }
        #expect(historyKey == key)
        #expect(beforeMessageID == 44)
        #expect(limit == 50)
        #expect(model.isLoadingOlderMessages)

        core.emit(
            .conversationHistoryLoaded(
                requestID: historyRequestID,
                page: LiveConversationPage(
                    key: key,
                    messages: [
                        LiveMessageSnapshot(
                            messageID: 42,
                            senderID: 22,
                            senderFullName: "Theo Martin",
                            timestamp: Date(timeIntervalSince1970: 1_699_999_900),
                            content: [.paragraph([.text("Earlier")])],
                            streamID: 5,
                            topic: "macOS",
                            recipientIDs: []
                        ),
                        LiveMessageSnapshot(
                            messageID: 44,
                            senderID: 22,
                            senderFullName: "Theo Martin",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                            content: [.paragraph([.text("Hello world")])],
                            streamID: 5,
                            topic: "macOS",
                            recipientIDs: []
                        ),
                    ],
                    foundOldest: true,
                    foundNewest: false
                )
            )
        )
        await eventually {
            guard case let .loaded(page) = model.conversationState else {
                return false
            }
            return page.messages.map(\.id) == [42, 44, 45]
                && page.beforeCursor == nil
                && !model.isLoadingOlderMessages
        }
    }

    @Test("Attachment upload inserts Markdown without sending and remains retryable")
    func attachmentUploadState() async throws {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore()
        )
        model.startObserving()
        let accountID = "account-media"
        let key = ConversationKey.topic(
            accountID: accountID,
            streamID: 5,
            topic: "macOS"
        )
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }
        model.openConversation(key)

        let fileURL = URL(fileURLWithPath: "/tmp/fixture image.png")
        model.uploadAttachment(fileURL, to: key)
        let upload = try #require(core.commands.last {
            if case .uploadAttachment = $0 { true } else { false }
        })
        guard case let .uploadAttachment(
            uploadID,
            commandAccountID,
            localPath,
            filename
        ) = upload else {
            Issue.record("Expected upload command")
            return
        }
        #expect(commandAccountID == accountID)
        #expect(localPath == "/tmp/fixture image.png")
        #expect(filename == "fixture image.png")
        #expect(model.attachmentUploadState == .uploading(filename: filename))

        core.emit(
            .attachmentUploaded(
                requestID: uploadID,
                attachment: LiveUploadedAttachment(
                    accountID: accountID,
                    filename: filename,
                    url: "/user_uploads/1/ab/fixture.png",
                    markdown: "[fixture image.png](/user_uploads/1/ab/fixture.png)"
                )
            )
        )
        await eventually { model.attachmentInsertion?.id == uploadID }
        #expect(model.attachmentInsertion?.key == key)
        #expect(
            model.attachmentInsertion?.markdown
                == "[fixture image.png](/user_uploads/1/ab/fixture.png)"
        )
        #expect(!core.commands.contains { if case .sendChannelMessage = $0 { true } else { false } })
        model.consumeAttachmentInsertion(id: uploadID)
        #expect(model.attachmentInsertion == nil)

        model.uploadAttachment(fileURL, to: key)
        guard case let .uploadAttachment(failedID, _, _, _) = core.commands.last else {
            Issue.record("Expected second upload command")
            return
        }
        core.emit(.failed(requestID: failedID, message: "fixture upload failure"))
        await eventually {
            model.attachmentUploadState
                == .failed(filename: filename, message: "fixture upload failure")
        }
        model.retryAttachmentUpload()
        #expect(model.attachmentUploadState == .uploading(filename: filename))
        #expect(core.commands.filter { if case .uploadAttachment = $0 { true } else { false } }.count == 3)
    }

    @Test("Media requests deduplicate, cache local URLs, and retry failures")
    func mediaState() async throws {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore()
        )
        model.startObserving()
        let accountID = "account-media"
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        let remoteURL = "/user_uploads/1/ab/image.png"
        model.loadMedia(remoteURL)
        model.loadMedia(remoteURL)
        let requests = core.commands.filter { if case .loadMedia = $0 { true } else { false } }
        #expect(requests.count == 1)
        guard case let .loadMedia(requestID, commandAccountID, requestedURL) = requests[0] else {
            Issue.record("Expected media request")
            return
        }
        #expect(commandAccountID == accountID)
        #expect(requestedURL == remoteURL)
        core.emit(
            .mediaReady(
                requestID: requestID,
                media: LiveCachedMedia(
                    accountID: accountID,
                    remoteURL: remoteURL,
                    localURL: "file:///tmp/private-cache.media",
                    contentType: "image/png",
                    byteCount: 12,
                    cacheHit: false
                )
            )
        )
        await eventually { model.mediaLocalURLs[remoteURL] != nil }
        #expect(model.mediaLocalURLs[remoteURL] == "file:///tmp/private-cache.media")

        let failedURL = "/user_uploads/1/ab/missing.png"
        model.loadMedia(failedURL)
        guard case let .loadMedia(failedID, _, _) = core.commands.last else {
            Issue.record("Expected failing media request")
            return
        }
        core.emit(.failed(requestID: failedID, message: "fixture media failure"))
        await eventually { model.mediaFailures[failedURL] == "fixture media failure" }
        model.retryMedia(failedURL)
        #expect(model.mediaFailures[failedURL] == nil)
        #expect(core.commands.filter { if case .loadMedia = $0 { true } else { false } }.count == 3)
    }

    @Test("Media wanted before the live session starts is requested once it does")
    func mediaDeferredUntilLiveSession() async throws {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore()
        )
        model.startObserving()
        let accountID = "account-deferred"
        core.emit(
            .cachedSessionLoaded(
                requestID: 1,
                identity: identity(accountID: accountID),
                snapshot: snapshot
            )
        )
        await eventually { model.identity != nil }

        // The core has no account session while only cached data is shown, so
        // asking now would fail for good.
        let iconURL = "/user_avatars/2/realm/icon.png"
        model.loadMedia(iconURL)
        func mediaRequests() -> [String] {
            core.commands.compactMap { command -> String? in
                if case let .loadMedia(_, _, remoteURL) = command {
                    return remoteURL
                }
                return nil
            }
        }
        #expect(mediaRequests().isEmpty)

        core.emit(
            .sessionStarted(
                requestID: 2,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }
        #expect(mediaRequests() == [iconURL])
    }

    @Test("Message actions expose pending, rollback, retry, and success states")
    func messageActions() async throws {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore()
        )
        model.startObserving()
        let accountID = "account-actions"
        let key = ConversationKey.topic(
            accountID: accountID,
            streamID: 5,
            topic: "macOS"
        )
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }
        model.openConversation(key)
        core.emit(
            .conversationOpened(
                requestID: 2,
                page: LiveConversationPage(
                    key: key,
                    messages: [
                        LiveMessageSnapshot(
                            messageID: 44,
                            senderID: 9,
                            senderFullName: "Maya Chen",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                            content: [.paragraph([.text("Original")])],
                            streamID: 5,
                            topic: "macOS",
                            recipientIDs: [],
                            flags: ["read"],
                            reactions: []
                        ),
                    ],
                    foundOldest: true,
                    foundNewest: true
                )
            )
        )
        await eventually { self.loadedMessage(model)?.id == 44 }
        let initial = try #require(loadedMessage(model))

        #expect(model.toggleStar(initial))
        let starCommand = try #require(core.commands.last {
            if case .updateMessageFlag = $0 { return true }
            return false
        })
        guard case let .updateMessageFlag(starID, _, [44], .starred, true) = starCommand else {
            Issue.record("Expected star command")
            return
        }
        #expect(loadedMessage(model)?.isStarred == true)
        #expect(loadedMessage(model)?.actionState == .pending(.star))

        core.emit(.failed(requestID: starID, message: "fixture rejection"))
        await eventually {
            self.loadedMessage(model)?.actionState
                == .failed(.star, message: "fixture rejection")
        }
        #expect(loadedMessage(model)?.isStarred == false)

        model.retryMessageAction(for: 44)
        let retry = try #require(core.commands.last)
        guard case let .updateMessageFlag(retryID, _, [44], .starred, true) = retry else {
            Issue.record("Expected star retry")
            return
        }
        core.emit(
            .messageFlagUpdated(
                requestID: retryID,
                messageIDs: [44],
                flag: .starred,
                added: true
            )
        )
        await eventually { self.loadedMessage(model)?.actionState == .idle }
        #expect(loadedMessage(model)?.isStarred == true)

        let starred = try #require(loadedMessage(model))
        #expect(model.toggleThumbsUp(starred))
        guard case let .updateReaction(reactionID, _, 44, "thumbs_up", true) = core.commands.last
        else {
            Issue.record("Expected reaction command")
            return
        }
        core.emit(
            .reactionUpdated(
                requestID: reactionID,
                messageID: 44,
                emojiName: "thumbs_up",
                added: true
            )
        )
        await eventually { self.loadedMessage(model)?.actionState == .idle }
        #expect(loadedMessage(model)?.reactionCount == 1)

        let reacted = try #require(loadedMessage(model))
        #expect(model.editMessage(reacted, content: "Edited"))
        guard case let .editMessage(editID, _, 44, "Edited") = core.commands.last else {
            Issue.record("Expected edit command")
            return
        }
        #expect(loadedMessage(model)?.plainText == "Edited")
        core.emit(.messageEdited(requestID: editID, messageID: 44, content: "Edited"))
        await eventually { self.loadedMessage(model)?.actionState == .idle }

        let edited = try #require(loadedMessage(model))
        #expect(model.deleteMessage(edited))
        guard case let .deleteMessage(deleteID, _, 44) = core.commands.last else {
            Issue.record("Expected delete command")
            return
        }
        core.emit(.messageDeleted(requestID: deleteID, messageID: 44))
        await eventually { self.loadedMessage(model) == nil }
    }

    @Test("Topic drafts, rename, move, and retry keep correlated state")
    func topicWorkflow() async throws {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore()
        )
        model.startObserving()
        let accountID = "account-1"
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        let draftKey = try #require(model.beginNewTopic(streamID: 5, name: " UI polish "))
        #expect(
            draftKey
                == .topic(accountID: accountID, streamID: 5, topic: "UI polish")
        )
        #expect(
            model.sidebarSnapshot?.channels.first?.topics
                .contains(where: { $0.name == "UI polish" }) == true
        )

        let oldKey = ConversationKey.topic(
            accountID: accountID,
            streamID: 5,
            topic: "macOS"
        )
        #expect(model.renameTopic(oldKey, anchorMessageID: 40, newName: "Native Mac"))
        guard case let .renameTopic(renameID, renameKey, messageID, newTopic)
            = core.commands.last
        else {
            Issue.record("Expected rename topic command")
            return
        }
        #expect(renameKey == oldKey)
        #expect(messageID == 40)
        #expect(newTopic == "Native Mac")
        core.emit(
            .topicUpdated(
                requestID: renameID,
                update: LiveTopicUpdate(
                    accountID: accountID,
                    streamID: 5,
                    oldTopic: "macOS",
                    newTopic: "Native Mac",
                    messageID: 40,
                    propagation: .changeAll
                )
            )
        )
        await eventually {
            model.topicActionState == .idle
                && model.sidebarSnapshot?.channels.first?.topics
                    .contains(where: { $0.name == "Native Mac" }) == true
        }

        let message = MessageViewData(
            id: 40,
            accountID: accountID,
            conversationKey: oldKey,
            senderID: 22,
            senderName: "Theo Martin",
            senderInitials: "TM",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            content: [.paragraph([.text("Move me")])],
            isOwnMessage: false,
            sourceStreamID: 5,
            sourceTopic: "Native Mac"
        )
        #expect(model.moveMessage(message, to: "UI polish"))
        guard case let .moveMessageToTopic(moveID, moveKey, movedID, destination)
            = core.commands.last
        else {
            Issue.record("Expected move message command")
            return
        }
        #expect(
            moveKey
                == .topic(
                    accountID: accountID,
                    streamID: 5,
                    topic: "Native Mac"
                )
        )
        #expect(movedID == 40)
        #expect(destination == "UI polish")

        core.emit(.failed(requestID: moveID, message: "temporary mock failure"))
        await eventually {
            if case .failed = model.topicActionState {
                return true
            }
            return false
        }
        model.retryTopicAction()
        guard case let .moveMessageToTopic(retryID, _, _, _) = core.commands.last else {
            Issue.record("Expected retry command")
            return
        }
        #expect(retryID != moveID)
        core.emit(
            .topicUpdated(
                requestID: retryID,
                update: LiveTopicUpdate(
                    accountID: accountID,
                    streamID: 5,
                    oldTopic: "Native Mac",
                    newTopic: "UI polish",
                    messageID: 40,
                    propagation: .changeOne
                )
            )
        )
        await eventually { model.topicActionState == .idle }
    }

    @Test("Topics the server no longer reports leave the sidebar")
    func staleTopicsDisappear() async throws {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore()
        )
        model.startObserving()
        let accountID = "account-1"
        let base = snapshot
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: LiveSnapshot(
                    revision: 1,
                    lastEventID: 10,
                    users: base.users,
                    channels: base.channels,
                    topics: [
                        LiveTopicSnapshot(streamID: 5, name: "macOS", maxMessageID: 40),
                        LiveTopicSnapshot(streamID: 5, name: "old name", maxMessageID: 30),
                    ],
                    messages: []
                )
            )
        )
        await eventually { model.connectionState == .connected }
        _ = try #require(model.beginNewTopic(streamID: 5, name: "draft topic"))

        func topicNames() -> Set<String> {
            Set(model.sidebarSnapshot?.channels.first?.topics.map(\.name) ?? [])
        }
        #expect(topicNames() == ["macOS", "old name", "draft topic"])

        // The core re-read the channel after a rename: "old name" is gone.
        core.emit(
            .snapshotUpdated(
                accountID: accountID,
                snapshot: LiveSnapshot(
                    revision: 2,
                    lastEventID: 11,
                    users: base.users,
                    channels: base.channels,
                    topics: [
                        LiveTopicSnapshot(streamID: 5, name: "macOS", maxMessageID: 40),
                        LiveTopicSnapshot(streamID: 5, name: "new name", maxMessageID: 41),
                    ],
                    messages: []
                )
            )
        )
        await eventually { topicNames().contains("new name") }
        #expect(topicNames() == ["macOS", "new name", "draft topic"])
    }

    @Test("Typing notices show who is typing and expire")
    func receivesTyping() async throws {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore()
        )
        model.startObserving()
        let accountID = "account-1"
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        let key = ConversationKey.directMessage(accountID: accountID, recipientIDs: [22])
        #expect(model.typingDescription(for: key) == nil)

        core.emit(.typingChanged(accountID: accountID, key: key, senderID: 22, isTyping: true))
        await eventually { model.typingDescription(for: key) == "Theo Martin is typing…" }

        // Your own typing, other accounts, and other conversations never show.
        core.emit(.typingChanged(accountID: accountID, key: key, senderID: 9, isTyping: true))
        core.emit(.typingChanged(accountID: "other", key: key, senderID: 23, isTyping: true))
        core.emit(.typingChanged(accountID: accountID, key: key, senderID: 22, isTyping: false))
        await eventually { model.typingDescription(for: key) == nil }
    }

    @Test("Typing is announced once, refreshed, and withdrawn")
    func sendsTyping() async throws {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore()
        )
        model.startObserving()
        let accountID = "account-1"
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        func typingCommands() -> [Bool] {
            core.commands.compactMap { command -> Bool? in
                guard case let .setTyping(_, _, isTyping) = command else { return nil }
                return isTyping
            }
        }
        let topic = ConversationKey.topic(accountID: accountID, streamID: 5, topic: "macOS")

        model.composerTyping(true, in: topic)
        model.composerTyping(true, in: topic)
        #expect(typingCommands() == [true], "keystrokes within the interval send one notice")

        model.composerTyping(false, in: topic)
        #expect(typingCommands() == [true, false])
        model.composerTyping(false, in: topic)
        #expect(typingCommands() == [true, false], "nothing to withdraw")

        // Collections and your own notes have nobody to tell.
        model.composerTyping(true, in: .mentions(accountID: accountID))
        model.composerTyping(true, in: .directMessage(accountID: accountID, recipientIDs: [9]))
        #expect(typingCommands() == [true, false])

        // Moving to another conversation withdraws the notice.
        model.composerTyping(true, in: topic)
        model.openConversation(.directMessage(accountID: accountID, recipientIDs: [22]))
        #expect(typingCommands() == [true, false, true, false])
    }

    @Test("Server search ignores stale responses and focuses the selected message")
    func messageSearchAndFocus() async throws {
        let core = RecordingCoreClient()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: MemoryCredentialStore()
        )
        model.startObserving()
        let accountID = "account-1"
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity(accountID: accountID),
                credential: StoredAPICredential(accountID: accountID, apiKey: "key"),
                snapshot: snapshot
            )
        )
        await eventually { model.connectionState == .connected }

        model.searchMessages("   ")
        #expect(model.messageSearchState == .idle)

        model.searchMessages("cancelled query")
        guard case let .searchMessages(cancelledRequestID, _, _, _) = core.commands.last else {
            Issue.record("Expected cancellable search command")
            return
        }
        model.clearMessageSearch()
        core.emit(.failed(requestID: cancelledRequestID, message: "stale failure"))
        await Task.yield()
        #expect(model.messageSearchState == .idle)
        #expect(model.connectionState == .connected)

        model.searchMessages("first query")
        guard case let .searchMessages(firstRequestID, _, firstQuery, firstLimit)
            = core.commands.last
        else {
            Issue.record("Expected first search command")
            return
        }
        #expect(firstQuery == "first query")
        #expect(firstLimit == 20)

        model.searchMessages("second query")
        guard case let .searchMessages(
            secondRequestID,
            commandAccountID,
            secondQuery,
            secondLimit
        ) = core.commands.last else {
            Issue.record("Expected second search command")
            return
        }
        #expect(commandAccountID == accountID)
        #expect(secondQuery == "second query")
        #expect(secondLimit == 20)

        core.emit(
            .searchCompleted(
                requestID: firstRequestID,
                accountID: accountID,
                results: []
            )
        )
        await Task.yield()
        #expect(model.messageSearchState == .loading(query: "second query"))

        let key = ConversationKey.topic(
            accountID: accountID,
            streamID: 5,
            topic: "Search topic"
        )
        let matchingMessage = LiveMessageSnapshot(
            messageID: 50,
            senderID: 22,
            senderFullName: "Theo Martin",
            timestamp: Date(timeIntervalSince1970: 1_700_000_050),
            content: [.paragraph([.text("Second query result")])],
            streamID: 5,
            topic: "Search topic",
            recipientIDs: []
        )
        core.emit(
            .searchCompleted(
                requestID: secondRequestID,
                accountID: accountID,
                results: [
                    LiveSearchResult(key: key, message: matchingMessage),
                    LiveSearchResult(key: key, message: matchingMessage),
                ]
            )
        )
        await eventually {
            if case let .loaded(query, results) = model.messageSearchState {
                return query == "second query"
                    && results.count == 1
                    && results.first?.accountID == accountID
                    && results.first?.conversationKey == key
                    && results.first?.contentPreview == "Second query result"
                    && results.first?.title == "Search topic"
                    && results.first?.subtitle == "#engineering"
            }
            return false
        }

        guard case let .loaded(_, results) = model.messageSearchState,
              let result = results.first
        else {
            Issue.record("Expected mapped search result")
            return
        }
        model.openSearchResult(result)
        guard case let .openMessage(
            focusRequestID,
            focusKey,
            messageID,
            numBefore,
            numAfter
        ) = core.commands.last else {
            Issue.record("Expected focused-message command")
            return
        }
        #expect(focusKey == key)
        #expect(messageID == 50)
        #expect(numBefore == 10)
        #expect(numAfter == 10)

        core.emit(
            .messageFocused(
                requestID: focusRequestID,
                messageID: 50,
                page: LiveConversationPage(
                    key: key,
                    messages: [matchingMessage],
                    foundOldest: false,
                    foundNewest: false
                )
            )
        )
        await eventually {
            guard case let .loaded(page) = model.conversationState else {
                return false
            }
            return page.key == key
                && page.focusedMessageID == 50
                && page.messages.map(\.id) == [50]
        }

        // An unrelated snapshot must not refetch the open conversation.
        let commandsBefore = core.commands.count
        core.emit(.snapshotUpdated(accountID: accountID, snapshot: snapshot))
        for _ in 0..<30 { await Task.yield() }
        #expect(!core.commands.dropFirst(commandsBefore).contains {
            if case .openConversation = $0 { return true }
            return false
        })

        // A new message in the open topic does.
        core.emit(
            .snapshotUpdated(
                accountID: accountID,
                snapshot: LiveSnapshot(
                    revision: snapshot.revision + 1,
                    lastEventID: snapshot.lastEventID + 1,
                    users: snapshot.users,
                    channels: snapshot.channels,
                    topics: snapshot.topics,
                    messages: snapshot.messages + [
                        LiveMessageSnapshot(
                            messageID: 51,
                            senderID: 9,
                            senderFullName: "Maya Chen",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_051),
                            content: [.paragraph([.text("Newer message")])],
                            streamID: 5,
                            topic: "Search topic",
                            recipientIDs: []
                        ),
                    ]
                )
            )
        )
        await eventually {
            core.commands.contains {
                if case let .openConversation(_, commandKey, _) = $0 {
                    return commandKey == key
                }
                return false
            }
        }
        let refreshedMessage = LiveMessageSnapshot(
            messageID: 51,
            senderID: 9,
            senderFullName: "Maya Chen",
            timestamp: Date(timeIntervalSince1970: 1_700_000_051),
            content: [.paragraph([.text("Newer message")])],
            streamID: 5,
            topic: "Search topic",
            recipientIDs: []
        )
        core.emit(
            .conversationOpened(
                requestID: 999,
                page: LiveConversationPage(
                    key: key,
                    messages: [refreshedMessage],
                    foundOldest: true,
                    foundNewest: true
                )
            )
        )
        await eventually {
            guard case let .loaded(page) = model.conversationState else {
                return false
            }
            return page.focusedMessageID == 50
                && page.messages.map(\.id) == [50, 51]
        }
    }

    private var snapshot: LiveSnapshot {
        LiveSnapshot(
            revision: 1,
            lastEventID: 10,
            users: [
                LiveUserSnapshot(
                    userID: 9,
                    fullName: "Maya Chen",
                    email: "maya@example.com",
                    isActive: true,
                    isBot: false,
                    avatarURL: "/user_avatars/2/maya.png"
                ),
                LiveUserSnapshot(
                    userID: 22,
                    fullName: "Theo Martin",
                    email: "theo@example.com",
                    isActive: true,
                    isBot: false,
                    avatarURL: "https://cdn.example.com/theo.png"
                ),
            ],
            channels: [
                LiveChannelSnapshot(
                    streamID: 5,
                    name: "engineering",
                    colorHex: "#76ce90",
                    isMuted: false
                ),
            ],
            topics: [
                LiveTopicSnapshot(
                    streamID: 5,
                    name: "macOS",
                    maxMessageID: 40
                ),
            ],
            messages: [
                LiveMessageSnapshot(
                    messageID: 40,
                    senderID: 22,
                    senderFullName: "Theo Martin",
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    content: [.paragraph([.text("Initial")])],
                    streamID: 5,
                    topic: "macOS",
                    recipientIDs: []
                ),
            ],
            realmIconURL: "/user_avatars/2/realm/icon.png"
        )
    }

    private func isAPIKeyStart(_ command: BridgeCommand) -> Bool {
        if case .startAPIKeySession = command {
            return true
        }
        return false
    }

    private func identity(accountID: String) -> LiveSessionIdentity {
        LiveSessionIdentity(
            accountID: accountID,
            serverURL: "https://acme.zulipchat.com",
            email: "maya@example.com",
            userID: 9,
            fullName: "Maya Chen"
        )
    }

    private func loadedMessage(_ model: LiveSessionViewModel) -> MessageViewData? {
        guard case let .loaded(page) = model.conversationState else { return nil }
        return page.messages.first(where: { $0.id == 44 })
    }

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<100 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for asynchronous state")
    }
}

private final class RecordingCoreClient: CoreClientProtocol, @unchecked Sendable {
    let events: AsyncStream<BridgeEvent>
    private let continuation: AsyncStream<BridgeEvent>.Continuation
    private let lock = NSLock()
    private var submitted: [BridgeCommand] = []

    init() {
        let pair = AsyncStream<BridgeEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    var commands: [BridgeCommand] {
        lock.withLock { submitted }
    }

    func submit(_ command: BridgeCommand) {
        lock.withLock {
            submitted.append(command)
        }
    }

    func emit(_ event: BridgeEvent) {
        continuation.yield(event)
    }
}

private actor MemoryCredentialStore: CredentialStore {
    private var credential: StoredAPICredential?

    func save(_ credential: StoredAPICredential) {
        self.credential = credential
    }

    func load(accountID: String) throws -> StoredAPICredential {
        guard let credential, credential.accountID == accountID else {
            throw CredentialStoreError.notFound
        }
        return credential
    }

    func delete(accountID: String) {
        if credential?.accountID == accountID {
            credential = nil
        }
    }

    func savedCredential() -> StoredAPICredential? {
        credential
    }
}
