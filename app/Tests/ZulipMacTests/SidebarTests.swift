import Testing
@testable import ZulipMac
import ZulipCoreBindings

@Suite("Fixture sidebar")
@MainActor
struct SidebarTests {
    @Test("Required navigation destinations are present")
    func requiredQuickLinks() {
        let titles = Set(FixtureSidebar.snapshot.quickLinks.map(\.title))
        #expect(titles == ["Inbox", "Mentions", "Starred", "Drafts"])
    }

    @Test("Every fixture item preserves the account identity")
    func accountIsolation() {
        let model = SidebarViewModel(snapshot: FixtureSidebar.snapshot)

        #expect(
            FixtureSidebar.snapshot.quickLinks.allSatisfy {
                $0.key.accountID == FixtureSidebar.accountID
            }
        )
        #expect(
            FixtureSidebar.snapshot.channels.allSatisfy {
                model.key(for: $0).accountID == FixtureSidebar.accountID
            }
        )
        #expect(
            FixtureSidebar.snapshot.directMessages.allSatisfy {
                model.key(for: $0).accountID == FixtureSidebar.accountID
            }
        )
    }

    @Test("Sections collapse independently")
    func sectionCollapse() {
        let model = SidebarViewModel(snapshot: FixtureSidebar.snapshot)

        model.toggleChannels()
        #expect(model.areChannelsExpanded == false)
        #expect(model.areDirectMessagesExpanded == true)

        model.toggleDirectMessages()
        #expect(model.areChannelsExpanded == false)
        #expect(model.areDirectMessagesExpanded == false)
    }

    @Test("Fixture unread counts are nonnegative")
    func unreadCounts() {
        #expect(FixtureSidebar.snapshot.quickLinks.allSatisfy { $0.unreadCount >= 0 })
        #expect(FixtureSidebar.snapshot.channels.allSatisfy { $0.unreadCount >= 0 })
        #expect(FixtureSidebar.snapshot.directMessages.allSatisfy { $0.unreadCount >= 0 })
    }
}
