import Foundation
import Testing
import ZulipCoreBindings
@testable import ZulipMac

@Suite("Message notifications")
@MainActor
struct NotificationTests {
    private let identity = LiveSessionIdentity(
        accountID: "acme|maya",
        serverURL: "https://acme.zulipchat.com",
        email: "maya@example.com",
        userID: 9,
        fullName: "Maya Chen"
    )

    @Test("The first snapshot only records existing messages")
    func firstSnapshotIsSilent() {
        var planner = NotificationPlanner()
        let existing = message(id: 1, direct: true)
        #expect(planner.plan(snapshot: snapshot([existing]), identity: identity).isEmpty)
        #expect(planner.plan(snapshot: snapshot([existing]), identity: identity).isEmpty)
    }

    @Test("Direct messages and mentions notify; other channel traffic does not")
    func notifiesOnlyForDirectMessagesAndMentions() throws {
        var planner = NotificationPlanner()
        planner.prime(with: snapshot([]))

        let notifications = planner.plan(
            snapshot: snapshot([
                message(id: 2, direct: true, text: "Lunch?"),
                message(id: 3, direct: false, flags: ["mentioned"], text: "@Maya please look"),
                message(id: 4, direct: false, text: "unrelated chatter"),
                message(id: 5, direct: false, flags: ["wildcard_mentioned"], streamID: 6),
                message(id: 6, direct: true, flags: ["read"]),
                message(id: 7, direct: true, senderID: 9),
            ]),
            identity: identity
        )

        #expect(notifications.map(\.route.messageID) == [2, 3, 5])
        #expect(notifications[0].title == "Theo Martin")
        #expect(notifications[0].body == "Lunch?")
        #expect(notifications[1].title == "Theo Martin in #engineering › macOS")
        #expect(
            notifications[1].route.key
                == .topic(accountID: "acme|maya", streamID: 5, topic: "macOS")
        )
        #expect(notifications[2].title == "Theo Martin in a channel › macOS")
        #expect(
            notifications[0].route.key
                == .directMessage(accountID: "acme|maya", recipientIDs: [22])
        )
    }

    @Test("Messages are announced once, long bodies are trimmed, bursts are capped")
    func deduplicatesTrimsAndCaps() {
        var planner = NotificationPlanner()
        planner.prime(with: snapshot([]))
        let long = String(repeating: "word ", count: 80)
        let burst = (10...20).map { message(id: Int64($0), direct: true, text: long) }

        let first = planner.plan(snapshot: snapshot(burst), identity: identity)
        #expect(first.count == NotificationPlanner.maximumPerBatch)
        #expect(first.map(\.route.messageID) == [16, 17, 18, 19, 20])
        #expect(first[0].body.count <= NotificationPlanner.maximumBodyLength)
        #expect(first[0].body.hasSuffix("…"))

        #expect(planner.plan(snapshot: snapshot(burst), identity: identity).isEmpty)
    }

    @Test("Muted channels stay silent even when mentioned")
    func mutedChannelsAreRespected() {
        var planner = NotificationPlanner()
        planner.prime(with: snapshot([]))
        let notifications = planner.plan(
            snapshot: snapshot(
                [message(id: 2, direct: false, flags: ["mentioned"])],
                mutedChannel: true
            ),
            identity: identity
        )
        #expect(notifications.isEmpty)
    }

    @Test("Notification routes survive the userInfo round trip")
    func routeRoundTrip() throws {
        let keys: [ConversationKey] = [
            .channel(accountID: "a", streamID: 5),
            .topic(accountID: "a", streamID: 5, topic: "ship: v1"),
            .directMessage(accountID: "a", recipientIDs: [3, 9]),
        ]
        for key in keys {
            let encoded = try #require(NotificationRoute(key: key, messageID: 42).encoded)
            let decoded = try #require(NotificationRoute(encoded: encoded))
            #expect(decoded == NotificationRoute(key: key, messageID: 42))
        }
        #expect(NotificationRoute(key: .inbox(accountID: "a"), messageID: 1).encoded == nil)
        #expect(NotificationRoute(encoded: "not json") == nil)
    }

    @Test("A live snapshot posts a notification and activation opens the conversation")
    func viewModelPostsAndRoutes() async {
        let core = NotifyingCoreClient()
        let notifier = RecordingNotifier()
        let model = LiveSessionViewModel(
            client: core,
            credentialStore: NullCredentialStore(),
            defaults: UserDefaults(suiteName: "notify-\(UUID().uuidString)") ?? .standard,
            notifier: notifier
        )
        model.isApplicationActive = { false }
        model.startObserving()
        core.emit(
            .sessionStarted(
                requestID: 1,
                identity: identity,
                credential: StoredAPICredential(accountID: identity.accountID, apiKey: "k"),
                snapshot: snapshot([])
            )
        )
        await eventually { model.connectionState == .connected }
        #expect(notifier.didRequestAuthorization)

        core.emit(
            .snapshotUpdated(
                accountID: identity.accountID,
                snapshot: snapshot(
                    [message(id: 2, direct: true, text: "Ping")],
                    unread: [LiveUnreadBucket(userIDs: [9, 22], count: 1)]
                )
            )
        )
        await eventually { !notifier.posted.isEmpty }
        #expect(notifier.posted.first?.body == "Ping")
        // The Dock badge counts unread messages, not notifications.
        #expect(notifier.badge == 1)

        let route = notifier.posted[0].route
        notifier.onActivate?(route)
        #expect(model.requestedTopicNavigation == route.key)

        core.emit(
            .snapshotUpdated(
                accountID: identity.accountID,
                snapshot: snapshot(
                    [
                        message(id: 2, direct: true, text: "Ping"),
                        message(id: 3, direct: true, text: "Again"),
                    ],
                    unread: [LiveUnreadBucket(userIDs: [9, 22], count: 2)]
                )
            )
        )
        await eventually { notifier.posted.count == 2 }
        #expect(notifier.badge == 2)

        // Reading everything elsewhere clears the badge.
        core.emit(
            .snapshotUpdated(
                accountID: identity.accountID,
                snapshot: snapshot([
                    message(id: 2, direct: true, flags: ["read"], text: "Ping"),
                    message(id: 3, direct: true, flags: ["read"], text: "Again"),
                ])
            )
        )
        await eventually { notifier.badge == 0 }
    }

    @Test("Muted channels do not count toward the badge, mentions in others do")
    func badgeCountsDirectMessagesAndMentions() {
        let summary = UnreadSummary(
            buckets: [
                LiveUnreadBucket(userIDs: [22], count: 2),
                LiveUnreadBucket(userIDs: [9, 22, 23], count: 1),
                LiveUnreadBucket(streamID: 5, topic: "macOS", count: 10, mentionCount: 2),
                LiveUnreadBucket(streamID: 6, topic: "noise", count: 7, mentionCount: 1),
            ],
            selfUserID: 9,
            mutedChannels: [6]
        )

        #expect(summary.badge == 2 + 1 + 2)
        #expect(summary.mentions == 3)
        #expect(summary.unreadCount(streamID: 5) == 10)
        #expect(summary.unreadCount(streamID: 6) == 0)
        #expect(summary.unreadCount(streamID: 5, topic: "macOS") == 10)
        #expect(summary.unreadCount(directMessageWith: 22) == 2)
        #expect(summary.unreadCount(directMessageWith: 23) == 0, "group chats have no row")
    }

    @Test("Notes to yourself count against your own row")
    func selfConversationUnread() {
        let summary = UnreadSummary(
            buckets: [LiveUnreadBucket(userIDs: [], count: 1), LiveUnreadBucket(userIDs: [9], count: 1)],
            selfUserID: 9,
            mutedChannels: []
        )
        #expect(summary.unreadCount(directMessageWith: 9) == 2)
    }

    // MARK: - Helpers

    private func snapshot(
        _ messages: [LiveMessageSnapshot],
        mutedChannel: Bool = false,
        unread: [LiveUnreadBucket] = []
    ) -> LiveSnapshot {
        LiveSnapshot(
            revision: 1,
            lastEventID: 1,
            users: [],
            channels: [
                LiveChannelSnapshot(
                    streamID: 5,
                    name: "engineering",
                    colorHex: "#76ce90",
                    isMuted: mutedChannel
                ),
            ],
            messages: messages,
            unread: unread
        )
    }

    private func message(
        id: Int64,
        direct: Bool,
        flags: [String] = [],
        streamID: Int64 = 5,
        senderID: Int64 = 22,
        text: String = "Hello"
    ) -> LiveMessageSnapshot {
        LiveMessageSnapshot(
            messageID: id,
            senderID: senderID,
            senderFullName: "Theo Martin",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            content: [.paragraph([.text(text)])],
            streamID: direct ? nil : streamID,
            topic: direct ? nil : "macOS",
            recipientIDs: direct ? [9, 22] : [],
            flags: flags
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for asynchronous state")
    }
}

@MainActor
private final class RecordingNotifier: MessageNotifier {
    var onActivate: ((NotificationRoute) -> Void)?
    var onApplicationActivated: (() -> Void)?
    var onNotificationsDisabled: (() -> Void)?
    private(set) var posted: [MessageNotification] = []
    private(set) var badge = 0
    private(set) var didRequestAuthorization = false

    func requestAuthorization() {
        didRequestAuthorization = true
    }

    func post(_ notification: MessageNotification) {
        posted.append(notification)
    }

    func setBadge(_ count: Int) {
        badge = count
    }
}

private final class NotifyingCoreClient: CoreClientProtocol, @unchecked Sendable {
    let events: AsyncStream<BridgeEvent>
    private let continuation: AsyncStream<BridgeEvent>.Continuation

    init() {
        let pair = AsyncStream<BridgeEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func submit(_ command: BridgeCommand) {}

    func emit(_ event: BridgeEvent) {
        continuation.yield(event)
    }
}

private actor NullCredentialStore: CredentialStore {
    func save(_ credential: StoredAPICredential) {}

    func load(accountID: String) throws -> StoredAPICredential {
        throw CredentialStoreError.notFound
    }

    func delete(accountID: String) {}
}
