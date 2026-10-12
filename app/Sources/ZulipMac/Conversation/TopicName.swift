import Foundation

/// How topic names appear in the interface.
enum TopicName {
    /// Zulip's default topic of a channel: the server stores it as an empty name.
    static let generalChat = "general chat"

    static func display(_ topic: String) -> String {
        topic.isEmpty ? generalChat : topic
    }
}
