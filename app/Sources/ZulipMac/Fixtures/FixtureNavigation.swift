import ZulipCoreBindings

enum FixtureNavigation {
    struct Topic: Identifiable, Equatable {
        let streamID: Int64
        let name: String
        let unreadCount: Int

        var id: String { "\(streamID):\(name)" }
    }

    static let topics = [
        Topic(streamID: 10, name: "macOS client", unreadCount: 5),
        Topic(streamID: 10, name: "Rust core", unreadCount: 2),
        Topic(streamID: 10, name: "release 0.1", unreadCount: 1),
        Topic(streamID: 11, name: "UI review", unreadCount: 2),
        Topic(streamID: 11, name: "app icon", unreadCount: 0),
        Topic(streamID: 12, name: "launch checklist", unreadCount: 0),
    ]

    static let directory = NavigationDirectory(
        destinations:
            quickLinkDestinations
            + channelDestinations
            + topicDestinations
            + directMessageDestinations
    )

    static func topics(for streamID: Int64) -> [Topic] {
        topics.filter { $0.streamID == streamID }
    }

    private static var quickLinkDestinations: [NavigationDestination] {
        FixtureSidebar.snapshot.quickLinks.map {
            NavigationDestination(
                key: $0.key,
                title: $0.title,
                subtitle: "Northstar",
                systemImage: $0.systemImage,
                keywords: ["navigation", "unread"]
            )
        }
    }

    private static var channelDestinations: [NavigationDestination] {
        FixtureSidebar.snapshot.channels.map {
            NavigationDestination(
                key: .channel(
                    accountID: FixtureSidebar.accountID,
                    streamID: $0.streamID
                ),
                title: $0.name,
                subtitle: "Channel",
                systemImage: "number",
                keywords: ["stream", "channel"]
            )
        }
    }

    private static var topicDestinations: [NavigationDestination] {
        topics.map { topic in
            let channelName = FixtureSidebar.snapshot.channels
                .first { $0.streamID == topic.streamID }?
                .name ?? "channel"

            return NavigationDestination(
                key: .topic(
                    accountID: FixtureSidebar.accountID,
                    streamID: topic.streamID,
                    topic: topic.name
                ),
                title: topic.name,
                subtitle: "#\(channelName)",
                systemImage: "text.bubble",
                keywords: ["topic", channelName]
            )
        }
    }

    private static var directMessageDestinations: [NavigationDestination] {
        FixtureSidebar.snapshot.directMessages.map {
            NavigationDestination(
                key: .directMessage(
                    accountID: FixtureSidebar.accountID,
                    recipientIDs: [$0.userID]
                ),
                title: $0.displayName,
                subtitle: "Direct message",
                systemImage: "person.crop.circle",
                keywords: ["dm", "person", $0.initials]
            )
        }
    }
}
