import Observation
import ZulipCoreBindings

@MainActor
@Observable
final class SidebarViewModel {
    var snapshot: SidebarSnapshot

    var areChannelsExpanded = true
    var areDirectMessagesExpanded = true
    private(set) var expandedChannelIDs: Set<Int64>

    init(snapshot: SidebarSnapshot) {
        self.snapshot = snapshot
        expandedChannelIDs = Set(
            snapshot.channels
                .filter { !$0.topics.isEmpty }
                .map(\.streamID)
        )
    }

    func toggleChannels() {
        areChannelsExpanded.toggle()
    }

    func toggleDirectMessages() {
        areDirectMessagesExpanded.toggle()
    }

    func key(for channel: ChannelSnapshot) -> ConversationKey {
        .channel(accountID: snapshot.accountID, streamID: channel.streamID)
    }

    func key(for topic: TopicSnapshot) -> ConversationKey {
        .topic(
            accountID: snapshot.accountID,
            streamID: topic.streamID,
            topic: topic.name
        )
    }

    func isChannelExpanded(_ streamID: Int64) -> Bool {
        expandedChannelIDs.contains(streamID)
    }

    func toggleChannel(_ streamID: Int64) {
        if expandedChannelIDs.remove(streamID) == nil {
            expandedChannelIDs.insert(streamID)
        }
    }

    func replaceSnapshot(_ snapshot: SidebarSnapshot) {
        self.snapshot = snapshot
    }

    func key(for directMessage: DirectMessageSnapshot) -> ConversationKey {
        .directMessage(
            accountID: snapshot.accountID,
            recipientIDs: [directMessage.userID]
        )
    }
}
