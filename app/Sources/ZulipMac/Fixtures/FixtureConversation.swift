import Foundation
import ZulipCoreBindings

enum FixtureConversation {
    private struct Sender {
        let id: Int64
        let name: String
        let initials: String
    }

    private static let senders = [
        Sender(id: 42, name: "Hua Hai", initials: "HH"),
        Sender(id: 101, name: "Maya Chen", initials: "MC"),
        Sender(id: 102, name: "Theo Martin", initials: "TM"),
        Sender(id: 103, name: "Ari Wilson", initials: "AW"),
    ]

    private static let fixtureLines = [
        "The sidebar is feeling calm now. I pushed the spacing pass for review.",
        "The Rust actor can keep the queue state private and publish one immutable snapshot.",
        "I checked this at compact width; the composer stays pinned and the timeline remains readable.",
        "Could we keep the command palette results account-scoped from the first release?",
        "Yes. ConversationKey already carries accountID, including every fixture route.",
        "The next pass should cover native links, mentions, code, quotes, and images.",
        "Nice. I also added a thousand-message fixture so scrolling work stays honest.",
        "Let’s keep the surface quiet: message actions can appear on hover and keyboard focus.",
    ]

    static func page(
        for key: ConversationKey,
        messageCount: Int = 1_000
    ) -> ConversationPage {
        let destination = FixtureNavigation.directory.destination(for: key)
        let title = destination?.title ?? "Conversation"
        let subtitle = destination?.subtitle ?? "Northstar"
        let baseTimestamp = Date(timeIntervalSince1970: 1_785_400_000)

        let messages = (0..<messageCount).map { index in
            let sender = senders[index % senders.count]
            let line = fixtureLines[index % fixtureLines.count]
            let content: [ContentBlock]

            if index >= max(0, messageCount - FixtureContent.messages.count) {
                let fixtureIndex = index - max(0, messageCount - FixtureContent.messages.count)
                content = FixtureContent.messages[fixtureIndex]
            } else {
                content = [.paragraph([.text(line)])]
            }

            return MessageViewData(
                id: Int64(index + 1),
                accountID: key.accountID,
                conversationKey: key,
                senderID: sender.id,
                senderName: sender.name,
                senderInitials: sender.initials,
                timestamp: baseTimestamp.addingTimeInterval(Double(index * 90)),
                content: content,
                isOwnMessage: sender.id == 42,
                isStarred: index.isMultiple(of: 29),
                reactionCount: index.isMultiple(of: 11) ? (index % 4) + 1 : 0
            )
        }

        return ConversationPage(
            key: key,
            title: title,
            subtitle: subtitle,
            messages: messages,
            beforeCursor: "before:\(messages.first?.id ?? 0)"
        )
    }

    static func state(for key: ConversationKey) -> ConversationLoadState {
        let destination = FixtureNavigation.directory.destination(for: key)
        let title = destination?.title ?? "Conversation"
        let subtitle = destination?.subtitle ?? "Northstar"

        switch key {
        case .starred:
            return .empty(
                title: title,
                subtitle: subtitle,
                message: "Star a message to keep it here."
            )
        case .drafts:
            return .failure(
                title: title,
                subtitle: subtitle,
                message: "The fixture cache is temporarily unavailable."
            )
        case .mentions:
            return .offline(page(for: key, messageCount: 80))
        case let .channel(_, streamID) where streamID == 13:
            return .loading(title: title, subtitle: subtitle)
        default:
            return .loaded(page(for: key, messageCount: 1_000))
        }
    }
}
