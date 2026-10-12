import Foundation
import ZulipCoreBindings

/// A quote waiting above the composer; its Markdown is prepended on send, so the
/// text field itself stays free of quote syntax.
struct ComposerQuote: Equatable, Sendable {
    let senderName: String
    let snippet: String
    let markdown: String

    /// One-line preview of the quoted text.
    static func snippet(from text: String, limit: Int = 140) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else {
            return collapsed
        }
        return String(collapsed.prefix(limit)) + "…"
    }
}

/// Recognizes the "Name said:" line that precedes a quote block.
enum QuoteAttribution {
    struct Match: Equatable {
        let name: String
        let link: URL?
    }

    static func match(_ block: ContentBlock) -> Match? {
        guard case let .paragraph(inline) = block,
              case let .mention(name, _)? = inline.first
        else {
            return nil
        }
        var link: URL?
        var text = ""
        for item in inline.dropFirst() {
            switch item {
            case let .text(value):
                text += value
            case let .link(label, url):
                link = URL(string: url)
                text += label
            default:
                return nil
            }
        }
        guard text.trimmingCharacters(in: .whitespaces).lowercased() == "said:" else {
            return nil
        }
        return Match(name: name, link: link)
    }
}

/// Builds the Markdown Zulip clients use to quote or forward a message.
enum MessageQuote {
    /// `@_**Name|id** [said](link):` followed by the original text in a quote fence.
    static func markdown(
        senderName: String,
        senderID: Int64,
        permalink: String?,
        source: String
    ) -> String {
        let body = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: body) + 1))
        let name = senderName
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let said = permalink.map { "[said](\($0))" } ?? "said"
        return "@_**\(name)|\(senderID)** \(said):\n\(fence)quote\n\(body)\n\(fence)"
    }

    /// A link that opens the message in any Zulip client, or `nil` for an
    /// unusable server address.
    static func permalink(
        serverURL: String,
        streamID: Int64?,
        streamName: String?,
        topic: String?,
        recipientIDs: [Int64],
        messageID: Int64
    ) -> String? {
        var server = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while server.hasSuffix("/") {
            server.removeLast()
        }
        guard server.hasPrefix("https://") || server.hasPrefix("http://"), messageID > 0 else {
            return nil
        }
        if let streamID, let topic {
            let slug = streamName.map { "\(streamID)-\($0.replacingOccurrences(of: " ", with: "-"))" }
                ?? "\(streamID)"
            return "\(server)/#narrow/stream/\(hashEncoded(slug))"
                + "/topic/\(hashEncoded(topic))/near/\(messageID)"
        }
        let ids = recipientIDs.filter { $0 > 0 }.sorted()
        guard !ids.isEmpty else {
            return nil
        }
        let people = ids.map(String.init).joined(separator: ",")
        return "\(server)/#narrow/dm/\(people)-dm/near/\(messageID)"
    }

    /// Zulip's URL fragment encoding: percent-encoding with `.` in place of `%`.
    static func hashEncoded(_ text: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~"
        )
        return (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            .replacingOccurrences(of: "%", with: ".")
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}
