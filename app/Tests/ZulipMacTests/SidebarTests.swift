import SwiftUI
import Testing
import ZulipCoreBindings
@testable import ZulipMac

@Suite("Fixture sidebar")
@MainActor
struct SidebarTests {
    @Test("Required navigation destinations are present")
    func requiredQuickLinks() {
        let titles = Set(FixtureSidebar.snapshot.quickLinks.map(\.title))
        #expect(titles == ["Mentions", "Starred", "Drafts"])
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

    @Test("Channel topics expand independently and keep account-scoped routing")
    func channelTopics() {
        let topic = TopicSnapshot(streamID: 5, name: "macOS", maxMessageID: 44)
        let snapshot = SidebarSnapshot(
            accountID: "account-1",
            organizationName: "Acme",
            organizationHost: "acme.zulipchat.com",
            quickLinks: [],
            channels: [
                ChannelSnapshot(
                    streamID: 5,
                    name: "engineering",
                    colorHex: "#76ce90",
                    topics: [topic]
                ),
            ],
            directMessages: [],
            currentUserName: "Maya Chen",
            currentUserInitials: "MC"
        )
        let model = SidebarViewModel(snapshot: snapshot)

        #expect(model.isChannelExpanded(5))
        #expect(
            model.key(for: topic)
                == .topic(accountID: "account-1", streamID: 5, topic: "macOS")
        )
        model.toggleChannel(5)
        #expect(!model.isChannelExpanded(5))
        model.toggleChannel(5)
        #expect(model.isChannelExpanded(5))
    }

    @Test("Fixture unread counts are nonnegative")
    func unreadCounts() {
        #expect(FixtureSidebar.snapshot.quickLinks.allSatisfy { $0.unreadCount >= 0 })
        #expect(FixtureSidebar.snapshot.channels.allSatisfy { $0.unreadCount >= 0 })
        #expect(FixtureSidebar.snapshot.directMessages.allSatisfy { $0.unreadCount >= 0 })
    }

    @Test("Session controls expose the correct settings-menu actions")
    func sessionControls() {
        var didConnect = false
        let control = SidebarSessionControl(action: .connect) {
            didConnect = true
        }

        #expect(control.action.title == "Connect to Zulip…")
        #expect(control.action.systemImage == "bolt.horizontal.circle")
        #expect(control.action.role == nil)
        control.perform()
        #expect(didConnect)

        #expect(SidebarSessionAction.disconnect.title == "Disconnect")
        #expect(SidebarSessionAction.disconnect.role == .destructive)
    }

    @Test("The polished window shell renders in light and dark appearances")
    func windowAppearanceMatrix() {
        for colorScheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(
                content: PrototypeWindowView(connectToZulip: {})
                    .frame(width: 1_080, height: 720)
                    .preferredColorScheme(colorScheme)
            )
            renderer.scale = 1

            #expect(renderer.nsImage != nil)
        }
    }
}
