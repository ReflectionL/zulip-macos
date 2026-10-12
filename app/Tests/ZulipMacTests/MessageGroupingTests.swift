import Foundation
import Testing
import ZulipCoreBindings
@testable import ZulipMac

@Suite("Message grouping")
struct MessageGroupingTests {
    private let key = ConversationKey.topic(accountID: "acme", streamID: 5, topic: "macOS")
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("The same sender within the window forms one block")
    func sameSenderWithinWindow() {
        let messages = [
            message(1, sender: 9, at: 0),
            message(2, sender: 9, at: 60),
            message(3, sender: 9, at: 60 + 4 * 60),
        ]
        #expect(MessageGrouping.continuationIDs(in: messages) == [2, 3])
    }

    @Test("A different sender, a long pause, or a different topic starts a new block")
    func boundaries() {
        let messages = [
            message(1, sender: 9, at: 0),
            message(2, sender: 22, at: 10),
            message(3, sender: 22, at: 10 + 6 * 60),
            message(4, sender: 22, at: 10 + 6 * 60 + 5, topic: "other"),
            message(5, sender: 22, at: 10 + 6 * 60 + 10, topic: "other"),
        ]
        #expect(MessageGrouping.continuationIDs(in: messages) == [5])
    }

    @Test("Topic names are compared without regard to case")
    func topicCase() {
        let messages = [
            message(1, sender: 9, at: 0, topic: "macOS"),
            message(2, sender: 9, at: 10, topic: "MACOS"),
        ]
        #expect(MessageGrouping.continuationIDs(in: messages) == [2])
    }

    @Test("Each pause is measured from the previous message, not the block start")
    func chainedWindow() {
        let messages = [
            message(1, sender: 9, at: 0),
            message(2, sender: 9, at: 4 * 60),
            message(3, sender: 9, at: 8 * 60),
        ]
        #expect(MessageGrouping.continuationIDs(in: messages) == [2, 3])
    }

    @Test("A new calendar day always starts a new block")
    func calendarDayBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let beforeMidnight = Date(timeIntervalSince1970: 1_700_006_390)
        let afterMidnight = beforeMidnight.addingTimeInterval(20)
        #expect(!calendar.isDate(beforeMidnight, inSameDayAs: afterMidnight))

        let messages = [
            message(1, sender: 9, date: beforeMidnight),
            message(2, sender: 9, date: afterMidnight),
        ]
        #expect(MessageGrouping.continuationIDs(in: messages, calendar: calendar).isEmpty)
    }

    private func message(
        _ id: Int64,
        sender: Int64,
        at offset: TimeInterval = 0,
        date: Date? = nil,
        topic: String = "macOS"
    ) -> MessageViewData {
        MessageViewData(
            id: id,
            accountID: "acme",
            conversationKey: key,
            senderID: sender,
            senderName: "Sender \(sender)",
            senderInitials: "S",
            timestamp: date ?? base.addingTimeInterval(offset),
            content: [.paragraph([.text("m\(id)")])],
            isOwnMessage: false,
            sourceStreamID: 5,
            sourceTopic: topic
        )
    }
}
