import Foundation
import SwiftUI
import Testing
import ZulipCoreBindings
@testable import ZulipMac

@Suite("Live session presentation")
@MainActor
struct LiveSessionTests {
    @Test("Login defaults to the primary Zulip Cloud organization")
    func defaultServer() {
        let model = LiveSessionViewModel(
            client: RecordingCoreClient(),
            credentialStore: MemoryCredentialStore()
        )

        #expect(model.serverURL == "https://shitcreator.zulipchat.com")
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
        let savedCredential = await credentials.savedCredential()
        #expect(
            savedCredential
                == StoredAPICredential(accountID: accountID, apiKey: "derived-api-key")
        )
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
                            contentHTML: "<p>Hello <strong>world</strong></p>",
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
                return page.messages.first?.plainText
                    == "<p>Hello <strong>world</strong></p>"
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
        #expect(
            core.commands.contains {
                if case let .sendChannelMessage(
                    _,
                    commandAccountID,
                    streamID,
                    topic,
                    content,
                    _
                ) = $0 {
                    return commandAccountID == accountID
                        && streamID == 5
                        && topic == "macOS"
                        && content == "A reply"
                }
                return false
            }
        )
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
                    isBot: false
                ),
                LiveUserSnapshot(
                    userID: 22,
                    fullName: "Theo Martin",
                    email: "theo@example.com",
                    isActive: true,
                    isBot: false
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
            messages: [
                LiveMessageSnapshot(
                    messageID: 40,
                    senderID: 22,
                    senderFullName: "Theo Martin",
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    contentHTML: "<p>Initial</p>",
                    streamID: 5,
                    topic: "macOS",
                    recipientIDs: []
                ),
            ]
        )
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
