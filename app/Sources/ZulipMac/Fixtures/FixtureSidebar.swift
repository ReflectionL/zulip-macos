import ZulipCoreBindings

enum FixtureSidebar {
    static let accountID = "fixture-account"

    static let snapshot = SidebarSnapshot(
        accountID: accountID,
        organizationName: "Northstar",
        organizationHost: "northstar.zulipchat.com",
        quickLinks: [
            QuickLinkSnapshot(
                key: .inbox(accountID: accountID),
                title: "Inbox",
                systemImage: "tray.full",
                unreadCount: 12
            ),
            QuickLinkSnapshot(
                key: .mentions(accountID: accountID),
                title: "Mentions",
                systemImage: "at",
                unreadCount: 3
            ),
            QuickLinkSnapshot(
                key: .starred(accountID: accountID),
                title: "Starred",
                systemImage: "star"
            ),
            QuickLinkSnapshot(
                key: .drafts(accountID: accountID),
                title: "Drafts",
                systemImage: "doc.text",
                unreadCount: 2
            ),
        ],
        channels: [
            ChannelSnapshot(
                streamID: 10,
                name: "engineering",
                colorHex: "#6A8EAE",
                unreadCount: 8
            ),
            ChannelSnapshot(
                streamID: 11,
                name: "design",
                colorHex: "#B47E9B",
                unreadCount: 2
            ),
            ChannelSnapshot(
                streamID: 12,
                name: "launch",
                colorHex: "#C69B56"
            ),
            ChannelSnapshot(
                streamID: 13,
                name: "random",
                colorHex: "#759C72",
                isMuted: true
            ),
        ],
        directMessages: [
            DirectMessageSnapshot(
                userID: 101,
                displayName: "Maya Chen",
                initials: "MC",
                unreadCount: 2,
                presence: .active
            ),
            DirectMessageSnapshot(
                userID: 102,
                displayName: "Theo Martin",
                initials: "TM",
                presence: .idle
            ),
            DirectMessageSnapshot(
                userID: 103,
                displayName: "Ari Wilson",
                initials: "AW",
                presence: .offline
            ),
        ],
        currentUserName: "Hua Hai",
        currentUserInitials: "HH"
    )

    static let defaultSelection = ConversationKey.inbox(accountID: accountID)
}
