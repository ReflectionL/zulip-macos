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

    @Test("Password login is redacted, persisted as an API key, and opens Inbox")
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
                        return key == .inbox(accountID: accountID)
                    }
                    return false
                }
        }

        #expect(model.sidebarSnapshot?.channels.map(\.name) == ["engineering"])
        #expect(model.sidebarSnapshot?.currentUserName == "Maya Chen")
        #expect(
            model.sidebarSnapshot?.quickLinks.map(\.title)
                == ["Inbox", "Mentions", "Starred", "Unread"]
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

        core.emit(
            .conversationOpened(
                requestID: 99,
                page: LiveConversationPage(
                    key: .inbox(accountID: accountID),
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

    @Test("A loaded conversation is mapped safely and marked read")
    func openConversation() async {
        let core = RecordingCoreClient()
        let credentials = MemoryCredentialStore()
        let model = LiveSessionViewModel(client: core, credentialStore: credentials)
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
        #expect(limit == 10)
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
