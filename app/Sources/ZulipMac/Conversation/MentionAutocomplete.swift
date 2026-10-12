import Foundation

/// One entry in the `@` suggestion list.
struct MentionCandidate: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case person(userID: Int64)
        case everyone
        case topic
    }

    let kind: Kind
    let name: String
    let detail: String

    var id: String {
        switch kind {
        case let .person(userID): "user-\(userID)"
        case .everyone: "all"
        case .topic: "topic"
        }
    }

    var systemImage: String {
        switch kind {
        case .person: "person.crop.circle"
        case .everyone: "person.3"
        case .topic: "text.bubble"
        }
    }
}

/// Finds the `@` being typed and builds Zulip mention syntax for a choice.
enum MentionAutocomplete {
    struct Trigger: Equatable {
        /// From the `@` up to the caret.
        let range: Range<String.Index>
        let query: String
        /// `@_` was typed, which mentions without notifying.
        let isSilent: Bool
    }

    private static let maximumQueryLength = 40

    static func trigger(in text: String, caret: String.Index) -> Trigger? {
        guard caret <= text.endIndex else {
            return nil
        }
        var index = caret
        var scanned = 0
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character == "@" {
                if previous > text.startIndex {
                    let before = text[text.index(before: previous)]
                    guard before.isWhitespace || "([{>".contains(before) else {
                        return nil
                    }
                }
                var queryStart = text.index(after: previous)
                var isSilent = false
                if queryStart < caret, text[queryStart] == "_" {
                    isSilent = true
                    queryStart = text.index(after: queryStart)
                }
                return Trigger(
                    range: previous..<caret,
                    query: String(text[queryStart..<caret]),
                    isSilent: isSilent
                )
            }
            if character.isNewline || character == "*" {
                return nil
            }
            scanned += 1
            if scanned > maximumQueryLength {
                return nil
            }
            index = previous
        }
        return nil
    }

    /// Candidates whose name starts with, has a word starting with, or contains the query.
    static func suggestions(
        _ candidates: [MentionCandidate],
        query: String,
        limit: Int = 6
    ) -> [MentionCandidate] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            return Array(candidates.prefix(limit))
        }
        var scored: [(score: Int, order: Int, candidate: MentionCandidate)] = []
        for (order, candidate) in candidates.enumerated() {
            let name = candidate.name.lowercased()
            var score: Int?
            if name.hasPrefix(needle) {
                score = 0
            } else if name.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) {
                score = 1
            } else if name.contains(needle) {
                score = 2
            }
            if let score {
                scored.append((score, order, candidate))
            }
        }
        scored.sort { ($0.score, $0.order) < ($1.score, $1.order) }
        return scored.prefix(limit).map(\.candidate)
    }

    /// Text that replaces the typed `@query`, with a trailing space.
    static func replacement(
        for candidate: MentionCandidate,
        isSilent: Bool,
        among all: [MentionCandidate]
    ) -> String {
        switch candidate.kind {
        case .everyone:
            return "@**all** "
        case .topic:
            return "@**topic** "
        case let .person(userID):
            let isAmbiguous = all.filter { $0.name == candidate.name }.count > 1
            let label = isAmbiguous ? "\(candidate.name)|\(userID)" : candidate.name
            return "\(isSilent ? "@_**" : "@**")\(label)** "
        }
    }
}
