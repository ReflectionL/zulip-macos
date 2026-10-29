import SwiftUI

@main
struct ZulipMacApp: App {
    @State private var updates = UpdateController()
    /// Owned here, not by the window: a window's view is rebuilt whenever this
    /// scene's state changes, and every rebuild would create another session (and
    /// another notification delegate that replaces the working one).
    @State private var notifier: SystemMessageNotifier
    @State private var session: LiveSessionViewModel

    init() {
        let notifier = SystemMessageNotifier()
        _notifier = State(initialValue: notifier)
        _session = State(initialValue: LiveSessionViewModel(notifier: notifier))
    }

    var body: some Scene {
        WindowGroup(AppIdentity.displayName) {
            AppRootView(session: session)
                // System controls (prominent buttons, toggles, focus rings) use
                // the app's accent rather than the system one.
                .tint(AppTheme.Colors.accent)
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
                NotificationSettingsSection(notifier: notifier)
                LinkPreviewSettingsSection()
                UpdateSettingsSection(updates: updates)
                Section("Keyboard") {
                    LabeledContent("Quick switcher", value: "⌘K")
                    LabeledContent("Search messages", value: "⌘F")
                    LabeledContent("Mentions, Starred", value: "⌘1 – ⌘2")
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
            .tint(AppTheme.Colors.accent)
            .padding()
            .frame(width: 460)
        }
    }
}
