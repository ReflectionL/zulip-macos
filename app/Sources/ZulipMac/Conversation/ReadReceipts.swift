import Foundation
import ZulipCoreBindings

/// One person who has read the user's latest message.
struct ReadReceiptReader: Identifiable, Equatable, Sendable {
    let userID: Int64
    let name: String
    let initials: String
    let avatarURL: String?

    var id: Int64 { userID }
}

/// The user's latest sent message in a conversation and who has read it so far.
struct ReadReceiptDisplay: Equatable, Sendable {
    let messageID: Int64
    let readers: [ReadReceiptReader]
}

/// When read receipts apply and how often they are refreshed.
///
/// Zulip delivers no event when someone else reads a message, so the latest sent
/// message is polled with a growing delay: quickly right after sending, then about
/// once a minute, and not at all once everyone in a direct message has read it.
enum ReadReceiptPolicy {
    /// Avatars shown before the rest collapse into a "+N" chip.
    static let visibleReaderLimit = 4
    /// Never ask about the same message more often than this, however it is triggered.
    static let minimumRequestInterval: TimeInterval = 4

    private static let delays: [Duration] = [
        .seconds(6), .seconds(12), .seconds(20), .seconds(30), .seconds(45),
    ]
    private static let steadyDelay = Duration.seconds(60)

    /// How long to wait after the poll numbered `attempt` (starting at zero).
    static func delay(afterAttempt attempt: Int) -> Duration {
        delays.indices.contains(attempt) ? delays[attempt] : steadyDelay
    }

    /// Channels, topics and conversations with someone else; the combined feed and
    /// other cross-conversation lists would show receipts for unrelated messages.
    static func isSupported(_ key: ConversationKey, selfUserID: Int64) -> Bool {
        switch key {
        case .channel, .topic:
            true
        case let .directMessage(_, recipientIDs):
            recipientIDs.contains { $0 != selfUserID }
        case .inbox, .mentions, .starred, .unread, .drafts:
            false
        }
    }

    /// The user's newest message the server has accepted, which is the only one
    /// that shows receipts.
    static func targetMessageID(
        in messages: [MessageViewData],
        key: ConversationKey,
        selfUserID: Int64
    ) -> Int64? {
        guard isSupported(key, selfUserID: selfUserID) else {
            return nil
        }
        return messages.last {
            $0.isOwnMessage && $0.id > 0 && $0.deliveryState == .sent
        }?.id
    }

    /// Whether every other participant of a direct message has read the message,
    /// so asking again cannot reveal anything new. Channels are never complete.
    static func isComplete(
        readerIDs: [Int64],
        key: ConversationKey,
        selfUserID: Int64
    ) -> Bool {
        guard case let .directMessage(_, recipientIDs) = key else {
            return false
        }
        let others = Set(recipientIDs).subtracting([selfUserID])
        return !others.isEmpty && others.isSubset(of: Set(readerIDs))
    }
}
