import Foundation
import ZulipCoreBindings

/// Decides which consecutive messages share one visual block.
///
/// A message continues the previous block when the same person wrote both in
/// the same place within a short time window on the same calendar day.
enum MessageGrouping {
    /// Longest pause between two messages that still reads as one block.
    static let window: TimeInterval = 5 * 60

    /// Identifiers of messages that should render without their own header.
    static func continuationIDs(
        in messages: [MessageViewData],
        calendar: Calendar = .current
    ) -> Set<Int64> {
        var ids = Set<Int64>()
        for (previous, current) in zip(messages, messages.dropFirst())
            where continues(current, after: previous, calendar: calendar)
        {
            ids.insert(current.id)
        }
        return ids
    }

    /// Identifiers of messages that open a new calendar day, the first loaded
    /// message included. A date separator is drawn above each of them.
    static func dayStartIDs(
        in messages: [MessageViewData],
        calendar: Calendar = .current
    ) -> Set<Int64> {
        var ids = Set<Int64>()
        for (index, message) in messages.enumerated()
            where index == 0
            || !calendar.isDate(message.timestamp, inSameDayAs: messages[index - 1].timestamp)
        {
            ids.insert(message.id)
        }
        return ids
    }

    static func continues(
        _ current: MessageViewData,
        after previous: MessageViewData,
        calendar: Calendar = .current
    ) -> Bool {
        current.senderID == previous.senderID
            && current.conversationKey == previous.conversationKey
            && current.sourceStreamID == previous.sourceStreamID
            // Zulip treats topic names case-insensitively.
            && current.sourceTopic?.lowercased() == previous.sourceTopic?.lowercased()
            && abs(current.timestamp.timeIntervalSince(previous.timestamp)) < window
            && calendar.isDate(current.timestamp, inSameDayAs: previous.timestamp)
    }
}
