import Foundation

/// Decides how a just-sent message appears before the server returns its copy.
enum LocalEcho {
    /// Whether the server will render `content` differently from the plain text typed
    /// (Markdown, links, mentions, emoji, line breaks). Such a message is shown as a
    /// placeholder until the server copy arrives, because showing the raw source and
    /// then swapping it for the rendered message made the timeline flash.
    static func needsServerRendering(_ content: String) -> Bool {
        if content.contains(where: { "\n*_~`#>[]|@<\\".contains($0) }) {
            return true
        }
        if content.contains("://") || content.contains("www.") {
            return true
        }
        if content.range(of: #":[A-Za-z0-9_+\-]+:"#, options: .regularExpression) != nil {
            return true
        }
        // A leading list marker such as "- item", "+ item" or "1. item".
        return content.range(of: #"^\s*([-+]|\d+[.)])\s"#, options: .regularExpression) != nil
    }
}
