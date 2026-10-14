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

    @Test("A channel set to notify announces every message; the account default applies otherwise")
    func followsChannelNotificationSettings() {
        var planner = NotificationPlanner()
        planner.prime(with: snapshot([]))
        let chatty = planner.plan(
            snapshot: snapshot(
                [message(id: 2, direct: false, text: "plain chatter")],
                channelNotifications: true
            ),
            identity: identity
        )
        #expect(chatty.map(\.route.messageID) == [2])

        let optedOut = planner.plan(
            snapshot: snapshot(
                [message(id: 2, direct: false), message(id: 3, direct: false)],
                channelNotifications: false,
                channelNotificationsDefault: true
            ),
            identity: identity
        )
        #expect(optedOut.isEmpty, "the channel's own choice beats the account default")

        let defaulted = planner.plan(
            snapshot: snapshot(
                [message(id: 2, direct: false), message(id: 3, direct: false), message(id: 4, direct: false)],
                channelNotificationsDefault: true
            ),
            identity: identity
        )
        #expect(defaulted.map(\.route.messageID) == [4])
    }

    @Test("Muted channels and topics stay quiet, followed topics always notify")
    func respectsMutedAndFollowedTopics() {
        var planner = NotificationPlanner()
        planner.prime(with: snapshot([]))

        let mutedTopic = planner.plan(
            snapshot: snapshot(
                [
                    message(id: 2, direct: false),
                    message(id: 3, direct: false, flags: ["wildcard_mentioned"]),
                ],
                channelNotifications: true,
                topicPolicies: [LiveTopicPolicy(streamID: 5, topic: "MACOS", visibility: .muted)]
            ),
            identity: identity
        )
        #expect(mutedTopic.isEmpty, "topic names compare without case; @all does not break through")

        let mutedChannel = planner.plan(
            snapshot: snapshot(
                [message(id: 2, direct: false), message(id: 3, direct: false)],
                mutedChannel: true,
                channelNotifications: true
            ),
            identity: identity
        )
        #expect(mutedChannel.isEmpty)

        let unmutedTopic = planner.plan(
            snapshot: snapshot(
                [message(id: 2, direct: false), message(id: 3, direct: false), message(id: 4, direct: false)],
                mutedChannel: true,
                channelNotifications: true,
                topicPolicies: [LiveTopicPolicy(streamID: 5, topic: "macOS", visibility: .unmuted)]
            ),
            identity: identity
        )
        #expect(unmutedTopic.map(\.route.messageID) == [4])

        let followed = planner.plan(
            snapshot: snapshot(
                (2...5).map { message(id: Int64($0), direct: false) },
                mutedChannel: true,
                topicPolicies: [LiveTopicPolicy(streamID: 5, topic: "macOS", visibility: .followed)]
            ),
            identity: identity
        )
        #expect(followed.map(\.route.messageID) == [5])
    }

    @Test("Muted topics add nothing to the unread counts or the badge")
    func mutedTopicsAreNotCounted() {
        let settings = ChannelNotificationSettings(
            snapshot: snapshot(
                [],
                topicPolicies: [
                    LiveTopicPolicy(streamID: 5, topic: "noise", visibility: .muted),
                ]
            )
        )
        let summary = UnreadSummary(
            buckets: [
                LiveUnreadBucket(streamID: 5, topic: "macOS", count: 4, mentionCount: 1),
                LiveUnreadBucket(streamID: 5, topic: "Noise", count: 9, mentionCount: 2),
            ],
            selfUserID: 9,
            mutedChannels: [],
            settings: settings
        )
        #expect(summary.unreadCount(streamID: 5) == 4)
        #expect(summary.unreadCount(streamID: 5, topic: "Noise") == 0)
        #expect(summary.badge == 1)
        #expect(summary.mentions == 3)
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

    @Test("Muted channels and topics still announce a personal @-mention, but not @all")
    func mentionsInMutedPlaces() {
        var planner = NotificationPlanner()
        planner.prime(with: snapshot([]))
        let mutedChannel = planner.plan(
            snapshot: snapshot(
                [
                    message(id: 2, direct: false, flags: ["mentioned"]),
                    message(id: 3, direct: false, flags: ["wildcard_mentioned"]),
                ],
                mutedChannel: true
            ),
            identity: identity
        )
        #expect(mutedChannel.map(\.route.messageID) == [2])

        let mutedTopic = planner.plan(
            snapshot: snapshot(
                [
                    message(id: 4, direct: false, flags: ["mentioned"]),
                    message(id: 5, direct: false, flags: ["wildcard_mentioned"]),
                    message(id: 6, direct: false, flags: ["mentioned"]),
                ],
                topicPolicies: [LiveTopicPolicy(streamID: 5, topic: "macOS", visibility: .muted)]
            ),
            identity: identity
        )
        #expect(mutedTopic.map(\.route.messageID) == [4, 6])
    }

    @Test("A topic reports Zulip's own choice: followed, default, muted or unmuted")
    func topicNotificationLevels() {
        let settings = ChannelNotificationSettings(
            snapshot: snapshot(
                [],
                mutedChannel: true,
                topicPolicies: [
                    LiveTopicPolicy(streamID: 5, topic: "Releases", visibility: .followed),
                    LiveTopicPolicy(streamID: 5, topic: "noise", visibility: .muted),
                    LiveTopicPolicy(streamID: 5, topic: "Plans", visibility: .unmuted),
                ]
            )
        )
        #expect(settings.level(streamID: 5, topic: "releases") == .followed)
        #expect(settings.level(streamID: 5, topic: "Noise") == .muted)
        #expect(settings.level(streamID: 5, topic: "plans") == .unmuted)
        #expect(settings.level(streamID: 5, topic: "other") == .standard)
        #expect(!settings.isMuted(streamID: 5, topic: "Releases"), "following unmutes")
        #expect(settings.isMuted(streamID: 5, topic: "other"), "default follows the muted channel")
        #expect(settings.notifies(streamID: 5, topic: "Releases", isPersonalMention: false))
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
        channelNotifications: Bool? = nil,
        channelNotificationsDefault: Bool = false,
        topicPolicies: [LiveTopicPolicy] = [],
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
                    isMuted: mutedChannel,
                    desktopNotifications: channelNotifications
                ),
            ],
            messages: messages,
            unread: unread,
            topicPolicies: topicPolicies,
            channelNotificationsDefault: channelNotificationsDefault
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
