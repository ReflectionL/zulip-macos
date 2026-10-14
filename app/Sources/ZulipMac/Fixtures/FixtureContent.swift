import ZulipCoreBindings

enum FixtureContent {
    static let messages: [[ContentBlock]] = [
        [
            .paragraph([
                .text("The native renderer supports "),
                .link(label: "safe links", url: "https://zulip.com/help/format-your-message-using-markdown"),
                .text(", "),
                .mention(displayName: "Maya Chen", userID: 101),
                .text(", and custom emoji "),
                .emoji(name: "zulip", value: "🦓"),
                .text("."),
            ]),
        ],
        [
            .quote([
                .paragraph([
                    .text("The interface should feel quiet until an action is needed."),
                ]),
            ]),
        ],
        [
            .list(
                items: [
                    [.paragraph([.text("Keep network work off the main actor")])],
                    [.paragraph([.text("Keep credentials in Keychain")])],
                    [.paragraph([.text("Keep snapshots account-scoped")])],
                ],
                ordered: false
            ),
        ],
        [
            .list(
                items: [
                    [.paragraph([.text("Submit CoreCommand")])],
                    [.paragraph([.text("Reduce state in Rust")])],
                    [.paragraph([.text("Publish an immutable snapshot")])],
                ],
                ordered: true
            ),
        ],
        [
            .code(
                language: "rust",
                value: """
                match command {
                    CoreCommand::OpenConversation(key) => actor.open(key),
                    CoreCommand::SendMessage(draft) => actor.send(draft),
                }
                """
            ),
        ],
        [
            .image(
                url: "fixture://native-preview",
                alt: "Native Zulip Mac conversation preview",
                width: 960,
                height: 540
            ),
        ],
        [
            .paragraph([
                .emoji(name: "check", value: "✅"),
                .text(" Every block above is SwiftUI; no web view is involved."),
            ]),
        ],
        [
            .linkPreview(
                url: "https://zulip.com/help/",
                title: "Zulip help center",
                description: "Guides for using Zulip, from getting started to advanced features.",
                imageURL: nil,
                fromServer: true
            ),
        ],
        [
            .unsupported(summary: "Unsupported fixture content is shown safely."),
        ],
    ]

    static let allBlocks = messages.flatMap { $0 }
}
