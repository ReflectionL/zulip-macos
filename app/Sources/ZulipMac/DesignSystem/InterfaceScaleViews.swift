import SwiftUI

/// View-menu commands for the text size.
struct InterfaceScaleCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Increase Text Size") {
                InterfaceScale.shared.increase()
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Decrease Text Size") {
                InterfaceScale.shared.decrease()
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Actual Text Size") {
                InterfaceScale.shared.reset()
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}

/// Invisible buttons that add the Control-key shortcuts (and the unshifted ⌘=) next
/// to the menu's own.
struct InterfaceScaleShortcuts: View {
    var body: some View {
        ZStack {
            Button("Increase text size") { InterfaceScale.shared.increase() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Increase text size") { InterfaceScale.shared.increase() }
                .keyboardShortcut("=", modifiers: .control)
            Button("Increase text size") { InterfaceScale.shared.increase() }
                .keyboardShortcut("+", modifiers: .control)
            Button("Decrease text size") { InterfaceScale.shared.decrease() }
                .keyboardShortcut("-", modifiers: .control)
            Button("Actual text size") { InterfaceScale.shared.reset() }
                .keyboardShortcut("0", modifiers: .control)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// Text-size row for the Settings window.
struct TextSizeSettingsSection: View {
    private var scale: InterfaceScale { InterfaceScale.shared }

    var body: some View {
        Section("Appearance") {
            LabeledContent("Text size") {
                HStack {
                    Button("Smaller") { scale.decrease() }
                        .disabled(!scale.canDecrease)
                    Text("\(Int((scale.factor * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(minWidth: 44)
                    Button("Larger") { scale.increase() }
                        .disabled(!scale.canIncrease)
                    Button("Reset") { scale.reset() }
                        .disabled(scale.isStandard)
                }
            }
        }
    }
}
