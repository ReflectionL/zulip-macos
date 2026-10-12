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

    static func continues(
        _ current: MessageViewData,
        after previous: MessageViewData,
        calendar: Calendar = .current
    ) -> Bool {
        current.senderID == previous.senderID
            && current.conversationKey == previous.conversationKey
            && current.sourceStreamID == previous.sourceStreamID
            && current.sourceTopic == previous.sourceTopic
            && abs(current.timestamp.timeIntervalSince(previous.timestamp)) < window
            && calendar.isDate(current.timestamp, inSameDayAs: previous.timestamp)
    }
}
