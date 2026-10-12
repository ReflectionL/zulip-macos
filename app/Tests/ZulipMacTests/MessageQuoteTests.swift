import Foundation
import Testing
@testable import ZulipMac

@Suite("Message quoting")
struct MessageQuoteTests {
    @Test("A quote names the sender, links the message and fences the text")
    func quoteFormat() {
        let text = MessageQuote.markdown(
            senderName: "Theo *Martin*",
            senderID: 22,
            permalink: "https://zulip.example.com/#narrow/stream/5-dev/topic/x/near/40",
            source: "  Hello **there**\n"
        )
        #expect(
            text == """
            @_**Theo Martin|22** [said](https://zulip.example.com/#narrow/stream/5-dev/topic/x/near/40):
            ```quote
            Hello **there**
            ```
            """
        )
    }

    @Test("The fence grows past any backticks in the quoted text")
    func longerFence() {
        let text = MessageQuote.markdown(
            senderName: "Theo",
            senderID: 22,
            permalink: nil,
            source: "```swift\nlet x = 1\n```"
        )
        #expect(text.hasPrefix("@_**Theo|22** said:\n````quote\n```swift"))
        #expect(text.hasSuffix("```\n````"))
    }

    @Test("Permalinks use Zulip's narrow syntax for topics and direct messages")
    func permalinks() {
        let topic = MessageQuote.permalink(
            serverURL: "https://zulip.example.com/",
            streamID: 5,
            streamName: "dev team",
            topic: "release 1.0?",
            recipientIDs: [],
            messageID: 40
        )
        #expect(
            topic == "https://zulip.example.com/#narrow/stream/5-dev-team"
                + "/topic/release.201.2E0.3F/near/40"
        )
        let direct = MessageQuote.permalink(
            serverURL: "https://zulip.example.com",
            streamID: nil,
            streamName: nil,
            topic: nil,
            recipientIDs: [30, 9],
            messageID: 41
        )
        #expect(direct == "https://zulip.example.com/#narrow/dm/9,30-dm/near/41")
        #expect(
            MessageQuote.permalink(
                serverURL: "not a url",
                streamID: 5,
                streamName: nil,
                topic: "x",
                recipientIDs: [],
                messageID: 40
            ) == nil
        )
    }
}
