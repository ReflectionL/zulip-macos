import Foundation
import Testing
@testable import ZulipMac

@Suite("Mention autocomplete")
struct MentionAutocompleteTests {
    private func person(_ id: Int64, _ name: String) -> MentionCandidate {
        MentionCandidate(kind: .person(userID: id), name: name, detail: "")
    }

    private func trigger(_ text: String, caretAfter marker: String? = nil) -> MentionAutocomplete.Trigger? {
        let caret: String.Index
        if let marker, let range = text.range(of: marker) {
            caret = range.upperBound
        } else {
            caret = text.endIndex
        }
        return MentionAutocomplete.trigger(in: text, caret: caret)
    }

    @Test("An @ at the start or after a space opens suggestions with the typed query")
    func triggers() {
        #expect(trigger("@")?.query == "")
        #expect(trigger("hello @th")?.query == "th")
        #expect(trigger("hello @Theo Mar")?.query == "Theo Mar")
        #expect(trigger("(@th")?.query == "th")
        #expect(trigger("hi @_th")?.isSilent == true)
        #expect(trigger("hi @_th")?.query == "th")
        #expect(trigger("hello @th and more", caretAfter: "@th")?.query == "th")
    }

    @Test("Emails, finished mentions and new lines do not trigger")
    func nonTriggers() {
        #expect(trigger("maya@example.com") == nil)
        #expect(trigger("@**Theo Martin** ok") == nil)
        #expect(trigger("@th\nnext line") == nil)
        #expect(trigger("no mention here") == nil)
        #expect(trigger("@" + String(repeating: "a", count: 60)) == nil)
    }

    @Test("Suggestions rank prefix matches before word and substring matches")
    func ranking() {
        let people = [
            person(1, "Maya Chen"),
            person(2, "Amy Park"),
            person(3, "Theo Martin"),
            person(4, "Mario Rossi"),
        ]
        #expect(
            MentionAutocomplete.suggestions(people, query: "ma").map(\.name)
                == ["Maya Chen", "Mario Rossi", "Theo Martin"]
        )
        #expect(MentionAutocomplete.suggestions(people, query: "park").map(\.name) == ["Amy Park"])
        #expect(MentionAutocomplete.suggestions(people, query: "zz").isEmpty)
        #expect(MentionAutocomplete.suggestions(people, query: "", limit: 2).count == 2)
    }

    @Test("Replacements use Zulip syntax and disambiguate repeated names")
    func replacements() {
        let theo = person(3, "Theo Martin")
        let twin = person(5, "Maya Chen")
        let other = person(6, "Maya Chen")
        let everyone = MentionCandidate(kind: .everyone, name: "all", detail: "")
        let topic = MentionCandidate(kind: .topic, name: "topic", detail: "")
        let all = [theo, twin, other, everyone, topic]
        #expect(MentionAutocomplete.replacement(for: theo, isSilent: false, among: all) == "@**Theo Martin** ")
        #expect(MentionAutocomplete.replacement(for: theo, isSilent: true, among: all) == "@_**Theo Martin** ")
        #expect(MentionAutocomplete.replacement(for: twin, isSilent: false, among: all) == "@**Maya Chen|5** ")
        #expect(MentionAutocomplete.replacement(for: everyone, isSilent: false, among: all) == "@**all** ")
        #expect(MentionAutocomplete.replacement(for: topic, isSilent: true, among: all) == "@**topic** ")
    }
}
