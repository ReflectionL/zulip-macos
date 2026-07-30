import Observation
import ZulipCoreBindings

@MainActor
@Observable
final class SidebarViewModel {
    var snapshot: SidebarSnapshot

    var areChannelsExpanded = true
    var areDirectMessagesExpanded = true

    init(snapshot: SidebarSnapshot) {
        self.snapshot = snapshot
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

    func key(for directMessage: DirectMessageSnapshot) -> ConversationKey {
        .directMessage(
            accountID: snapshot.accountID,
            recipientIDs: [directMessage.userID]
        )
    }
}
