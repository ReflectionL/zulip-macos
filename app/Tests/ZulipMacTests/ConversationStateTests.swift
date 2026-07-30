import SwiftUI
import Testing
import ZulipCoreBindings
@testable import ZulipMac

@Suite("Conversation states and accessibility")
struct ConversationStateTests {
    @Test("Navigation fixtures expose empty, loading, error, offline, and loaded states")
    func fixtureStates() {
        let accountID = FixtureSidebar.accountID

        #expect(
            isEmpty(
                FixtureConversation.state(for: .starred(accountID: accountID))
            )
        )
        #expect(
            isFailure(
                FixtureConversation.state(for: .drafts(accountID: accountID))
            )
        )
        #expect(
            isOffline(
                FixtureConversation.state(for: .mentions(accountID: accountID))
            )
        )
        #expect(
            isLoading(
                FixtureConversation.state(
                    for: .channel(accountID: accountID, streamID: 13)
                )
            )
        )
        #expect(
            isLoaded(
                FixtureConversation.state(for: .inbox(accountID: accountID))
            )
        )
    }

    @Test(
        "Every state renders in light and dark",
        arguments: [ColorScheme.light, .dark]
    )
    @MainActor
    func stateSnapshots(colorScheme: ColorScheme) {
        let states: [ConversationLoadState] = [
            .loading(title: "random", subtitle: "Channel"),
            .empty(
                title: "Starred",
                subtitle: "Northstar",
                message: "Star a message to keep it here."
            ),
            .failure(
                title: "Drafts",
                subtitle: "Northstar",
                message: "The fixture cache is temporarily unavailable."
            ),
            .offline(
                FixtureConversation.page(
                    for: .mentions(accountID: FixtureSidebar.accountID),
                    messageCount: 12
                )
            ),
        ]

        for state in states {
            let renderer = ImageRenderer(
                content: ConversationStateView(state: state, retry: {})
                    .frame(width: 820, height: 620)
                    .environment(\.colorScheme, colorScheme)
            )
            #expect(renderer.nsImage?.size == .init(width: 820, height: 620))
        }
    }

    private func isEmpty(_ state: ConversationLoadState) -> Bool {
        if case .empty = state { true } else { false }
    }

    private func isFailure(_ state: ConversationLoadState) -> Bool {
        if case .failure = state { true } else { false }
    }

    private func isOffline(_ state: ConversationLoadState) -> Bool {
        if case .offline = state { true } else { false }
    }

    private func isLoading(_ state: ConversationLoadState) -> Bool {
        if case .loading = state { true } else { false }
    }

    private func isLoaded(_ state: ConversationLoadState) -> Bool {
        if case .loaded = state { true } else { false }
    }
}
