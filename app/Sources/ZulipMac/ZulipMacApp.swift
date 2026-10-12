import SwiftUI

@main
struct ZulipMacApp: App {
    var body: some Scene {
        WindowGroup(AppIdentity.displayName) {
            AppRootView()
        }
        .defaultSize(width: 1_080, height: 720)
        .windowStyle(.hiddenTitleBar)

        Settings {
            Form {
                LabeledContent("Application", value: AppIdentity.displayName)
                LabeledContent("Minimum system", value: AppIdentity.minimumSystem)
                Section("Keyboard") {
                    LabeledContent("Quick switcher", value: "⌘K")
                    LabeledContent("Search messages", value: "⌘F")
                    LabeledContent("Inbox, Mentions, Starred, Unread", value: "⌘1 – ⌘4")
                    LabeledContent("Previous / next conversation", value: "⌥⌘↑ / ⌥⌘↓")
                    LabeledContent("Focus message composer", value: "⇧⌘L")
                    LabeledContent("Send message", value: "Return")
                    LabeledContent("Leave composer, close search", value: "Esc")
                    LabeledContent("Toggle sidebar", value: "⌃⌘S")
                }
            }
            .formStyle(.grouped)
            .padding()
            .frame(width: 460)
        }
    }
}
