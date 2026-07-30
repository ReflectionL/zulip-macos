import Testing
@testable import ZulipMac
import ZulipCoreBindings

@Suite("Fixture navigation")
@MainActor
struct NavigationTests {
    @Test("Conversation identities remain account scoped")
    func stableConversationIdentity() {
        let first = ConversationKey.topic(
            accountID: "one",
            streamID: 10,
            topic: "Rust core"
        )
        let same = ConversationKey.topic(
            accountID: "one",
            streamID: 10,
            topic: "Rust core"
        )
        let otherAccount = ConversationKey.topic(
            accountID: "two",
            streamID: 10,
            topic: "Rust core"
        )

        #expect(first == same)
        #expect(first != otherAccount)
    }

    @Test("Search ranks exact and prefix matches")
    func searchRanking() {
        let results = FixtureNavigation.directory.search("design")
        #expect(results.first?.title == "design")

        let topicResults = FixtureNavigation.directory.search("rust")
        #expect(topicResults.first?.title == "Rust core")
    }

    @Test("Search finds people by initials")
    func searchKeywords() {
        let results = FixtureNavigation.directory.search("MC")
        #expect(results.first?.title == "Maya Chen")
    }

    @Test("Selection dismisses the command palette")
    func selectionFlow() {
        let store = NavigationStore(
            directory: FixtureNavigation.directory,
            initialSelection: FixtureSidebar.defaultSelection
        )
        let destination = FixtureNavigation.directory.search("Maya").first

        store.presentCommandPalette()
        #expect(store.isCommandPalettePresented)

        if let destination {
            store.select(destination.key)
        }

        #expect(store.selection == destination?.key)
        #expect(store.isCommandPalettePresented == false)
        #expect(store.query.isEmpty)
    }

    @Test("Unknown destinations cannot replace the selection")
    func rejectsUnknownDestination() {
        let store = NavigationStore(
            directory: FixtureNavigation.directory,
            initialSelection: FixtureSidebar.defaultSelection
        )

        store.select(.channel(accountID: FixtureSidebar.accountID, streamID: 9_999))

        #expect(store.selection == FixtureSidebar.defaultSelection)
    }
}
