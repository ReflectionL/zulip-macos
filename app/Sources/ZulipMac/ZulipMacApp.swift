import SwiftUI

@main
struct ZulipMacApp: App {
    @State private var updates = UpdateController()

    var body: some Scene {
        WindowGroup(AppIdentity.displayName) {
            AppRootView()
                .environment(updates)
                .task { await updates.checkAutomatically() }
        }
        .defaultSize(width: 1_080, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            UpdateCommands(updates: updates)
            InterfaceScaleCommands()
        }

        Settings {
            Form {
                LabeledContent("Application", value: AppIdentity.displayName)
                LabeledContent("Minimum system", value: AppIdentity.minimumSystem)
                TextSizeSettingsSection()
                UpdateSettingsSection(updates: updates)
                Section("Keyboard") {
                    LabeledContent("Quick switcher", value: "⌘K")
                    LabeledContent("Search messages", value: "⌘F")
                    LabeledContent("Inbox, Mentions, Starred, Unread", value: "⌘1 – ⌘4")
                    LabeledContent("Previous / next conversation", value: "⌥⌘↑ / ⌥⌘↓")
                    LabeledContent("Focus message composer", value: "⇧⌘L")
                    LabeledContent("Send message", value: "Return")
                    LabeledContent("New line in message", value: "⇧Return or ⌥Return")
                    LabeledContent("Leave composer, close search", value: "Esc")
                    LabeledContent("Toggle sidebar", value: "⌃⌘S")
                    LabeledContent("Larger / smaller text", value: "⌘+ / ⌘−")
                    LabeledContent("Actual text size", value: "⌘0")
                }
            }
            .formStyle(.grouped)
            .padding()
            .frame(width: 460)
        }
    }
}
