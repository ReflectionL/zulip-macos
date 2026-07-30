import Testing
import ZulipCoreBindings
@testable import ZulipMac

@Suite("Fixture conversation surface")
struct ConversationSurfaceTests {
    @Test("The large fixture creates 1,000 stable, account-scoped messages")
    func largeFixture() {
        let clock = ContinuousClock()
        let start = clock.now
        let page = FixtureConversation.page(
            for: FixtureSidebar.defaultSelection,
            messageCount: 1_000
        )
        let duration = start.duration(to: clock.now)

        #expect(page.messages.count == 1_000)
        #expect(Set(page.messages.map(\.id)).count == 1_000)
        #expect(
            page.messages.allSatisfy {
                $0.accountID == FixtureSidebar.accountID
                    && $0.conversationKey == FixtureSidebar.defaultSelection
            }
        )
        #expect(duration < .seconds(2))
    }

    @Test("Content blocks provide a safe plain-text timeline fallback")
    func plainTextFallback() {
        let message = MessageViewData(
            id: 1,
            accountID: FixtureSidebar.accountID,
            conversationKey: FixtureSidebar.defaultSelection,
            senderID: 101,
            senderName: "Maya Chen",
            senderInitials: "MC",
            timestamp: .now,
            content: [
                .paragraph([
                    .text("Review "),
                    .link(label: "the plan", url: "https://example.com"),
                    .text(" with "),
                    .mention(displayName: "Hua Hai", userID: 42),
                    .emoji(name: "thumbs_up", value: "👍"),
                ]),
            ],
            isOwnMessage: false
        )

        #expect(message.plainText == "Review the plan with @Hua Hai👍")
    }
}
