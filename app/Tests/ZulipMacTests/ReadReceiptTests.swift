import Foundation
import Testing
import ZulipCoreBindings
@testable import ZulipMac

@Suite("Read receipts")
struct ReadReceiptTests {
    private let topic = ConversationKey.topic(accountID: "acme", streamID: 5, topic: "macOS")
    private let directMessage = ConversationKey.directMessage(accountID: "acme", recipientIDs: [22])

    @Test("Only conversations with a clear audience show receipts")
    func supportedConversations() {
        #expect(ReadReceiptPolicy.isSupported(topic, selfUserID: 9))
        #expect(ReadReceiptPolicy.isSupported(.channel(accountID: "acme", streamID: 5), selfUserID: 9))
        #expect(ReadReceiptPolicy.isSupported(directMessage, selfUserID: 9))
        #expect(!ReadReceiptPolicy.isSupported(.inbox(accountID: "acme"), selfUserID: 9))
        #expect(!ReadReceiptPolicy.isSupported(.mentions(accountID: "acme"), selfUserID: 9))
        #expect(!ReadReceiptPolicy.isSupported(.starred(accountID: "acme"), selfUserID: 9))
        #expect(!ReadReceiptPolicy.isSupported(.unread(accountID: "acme"), selfUserID: 9))
        // Notes to self have nobody who could read them.
        #expect(
            !ReadReceiptPolicy.isSupported(
                .directMessage(accountID: "acme", recipientIDs: [9]),
                selfUserID: 9
            )
        )
    }

    @Test("The target is the newest sent message the server has accepted")
    func targetMessage() {
        let messages = [
            message(40, sender: 9, own: true),
            message(41, sender: 22, own: false),
            message(42, sender: 9, own: true),
            message(-3, sender: 9, own: true, delivery: .pending),
            message(43, sender: 22, own: false),
        ]
        #expect(
            ReadReceiptPolicy.targetMessageID(in: messages, key: topic, selfUserID: 9) == 42
        )
        #expect(
            ReadReceiptPolicy.targetMessageID(
                in: messages,
                key: .inbox(accountID: "acme"),
                selfUserID: 9
            ) == nil
        )
        #expect(
            ReadReceiptPolicy.targetMessageID(
                in: [message(41, sender: 22, own: false)],
                key: topic,
                selfUserID: 9
            ) == nil
        )
    }

    @Test("A direct message is complete once everyone else has read it")
    func completion() {
        #expect(
            ReadReceiptPolicy.isComplete(readerIDs: [22], key: directMessage, selfUserID: 9)
        )
        #expect(!ReadReceiptPolicy.isComplete(readerIDs: [], key: directMessage, selfUserID: 9))
        let group = ConversationKey.directMessage(accountID: "acme", recipientIDs: [9, 22, 23])
        #expect(!ReadReceiptPolicy.isComplete(readerIDs: [22], key: group, selfUserID: 9))
        #expect(ReadReceiptPolicy.isComplete(readerIDs: [22, 23], key: group, selfUserID: 9))
        // Channel audiences are open-ended, so polling never stops on its own.
        #expect(!ReadReceiptPolicy.isComplete(readerIDs: [22, 23], key: topic, selfUserID: 9))
    }

    @Test("Polling slows down and settles at about a minute")
    func pollingDelays() {
        #expect(ReadReceiptPolicy.delay(afterAttempt: 0) == .seconds(6))
        #expect(
            ReadReceiptPolicy.delay(afterAttempt: 1) > ReadReceiptPolicy.delay(afterAttempt: 0)
        )
        #expect(ReadReceiptPolicy.delay(afterAttempt: 5) == .seconds(60))
        #expect(ReadReceiptPolicy.delay(afterAttempt: 500) == .seconds(60))
    }

    private func message(
        _ id: Int64,
        sender: Int64,
        own: Bool,
        delivery: MessageDeliveryState = .sent
    ) -> MessageViewData {
        MessageViewData(
            id: id,
            accountID: "acme",
            conversationKey: topic,
            senderID: sender,
            senderName: "Sender \(sender)",
            senderInitials: "S",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            content: [],
            isOwnMessage: own,
            deliveryState: delivery
        )
    }
}
