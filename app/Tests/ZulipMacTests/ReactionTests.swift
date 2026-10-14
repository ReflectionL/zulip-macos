import Foundation
import Testing
import ZulipCoreBindings
@testable import ZulipMac

@Suite("Emoji reactions")
@MainActor
struct ReactionTests {
    private func message(reactions: [MessageReaction] = []) -> MessageViewData {
        MessageViewData(
            id: 1,
            accountID: "acme|maya",
            conversationKey: .topic(accountID: "acme|maya", streamID: 5, topic: "macOS"),
            senderID: 2,
            senderName: "Theo",
            senderInitials: "T",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            content: [.paragraph([.text("Hello")])],
            isOwnMessage: false,
            reactions: reactions
        )
    }

    @Test("Reactions group by emoji, count people and notice the user's own")
    func grouping() {
        let groups = LiveSessionViewModel.groupReactions(
            [
                LiveReactionSnapshot(
                    emojiName: "thumbs_up", emojiCode: "1f44d",
                    reactionType: "unicode_emoji", userID: 2
                ),
                LiveReactionSnapshot(
                    emojiName: "tada", emojiCode: "1f389",
                    reactionType: "unicode_emoji", userID: 2
                ),
                // Another alias of the same emoji joins the first group, and the
                // user's own name is the one kept for withdrawing it.
                LiveReactionSnapshot(
                    emojiName: "+1", emojiCode: "1f44d",
                    reactionType: "unicode_emoji", userID: 9
                ),
                LiveReactionSnapshot(emojiName: "zulip", userID: 3),
            ],
            me: 9
        )
        #expect(groups.map(\.count) == [2, 1, 1])
        #expect(groups[0].emojiName == "+1")
        #expect(groups[0].includesMe)
        #expect(!groups[1].includesMe)
        #expect(groups[2].emojiName == "zulip")
    }

    @Test("Adding and withdrawing keeps counts and drops empty groups")
    func applyReaction() {
        var item = message(reactions: [
            MessageReaction(
                emojiName: "heart", emojiCode: "2764",
                reactionType: "unicode_emoji", count: 2, includesMe: false
            ),
        ])
        let heart = ReactionTarget(name: "heart", code: "2764")
        let fire = ReactionTarget(name: "fire", code: "1f525")

        item.applyReaction(heart, add: true)
        #expect(item.reactions.first?.count == 3)
        #expect(item.reactions.first?.includesMe == true)

        item.applyReaction(fire, add: true)
        #expect(item.reactions.map(\.emojiName) == ["heart", "fire"])
        item.applyReaction(fire, add: false)
        #expect(item.reactions.map(\.emojiName) == ["heart"])

        item.applyReaction(heart, add: false)
        #expect(item.reactions.first?.count == 2)
        #expect(item.reactions.first?.includesMe == false)
    }

    @Test("Codes match whether or not they are padded")
    func codeNormalization() {
        let copyright = MessageReaction(
            emojiName: "copyright", emojiCode: "00a9", reactionType: "unicode_emoji"
        )
        #expect(ReactionTarget(name: "copyright", code: "a9").matches(copyright))
        #expect(!ReactionTarget(name: "heart", code: "2764").matches(copyright))
        // Without codes the name decides.
        #expect(ReactionTarget(name: "party").matches(MessageReaction(emojiName: "party")))
    }

    @Test("Emoji codes turn into characters")
    func glyphs() {
        #expect(EmojiCatalog.glyph(forCode: "1f44d") == "👍")
        #expect(EmojiCatalog.glyph(forCode: "2764") == "❤\u{FE0F}")
        #expect(EmojiCatalog.glyph(forCode: "0023-20e3") == "#\u{FE0F}\u{20E3}")
        #expect(EmojiCatalog.glyph(forCode: "not-hex") == nil)
        #expect(EmojiCatalog.recommended.allSatisfy { EmojiCatalog.glyph(forCode: $0.code) != nil })
    }

    @Test("The catalog is searchable by word and by pasted emoji")
    func search() {
        #expect(EmojiCatalog.all.count > 1000)
        #expect(EmojiCatalog.search("tada").contains { $0.code == "1f389" })
        #expect(EmojiCatalog.search("party popper").contains { $0.code == "1f389" })
        #expect(EmojiCatalog.search("🎉").map(\.code) == ["1f389"])
        #expect(EmojiCatalog.search("zzzzqq").isEmpty)
        #expect(EmojiCatalog.search("").count == EmojiCatalog.all.count)
    }
}
