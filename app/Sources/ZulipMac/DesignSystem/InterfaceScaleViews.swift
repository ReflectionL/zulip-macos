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

/// An invisible button that adds the unshifted ⌘= next to the menu's own ⌘+.
struct InterfaceScaleShortcuts: View {
    var body: some View {
        Button("Increase text size") { InterfaceScale.shared.increase() }
            .keyboardShortcut("=", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

/// Text-size and message-density rows for the Settings window.
struct TextSizeSettingsSection: View {
    private var scale: InterfaceScale { InterfaceScale.shared }
    private var densityPreference: MessageDensityPreference { MessageDensityPreference.shared }

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
            LabeledContent("Message density") {
                Picker(
                    "Message density",
                    selection: Binding(
                        get: { densityPreference.density },
                        set: { densityPreference.select($0) }
                    )
                ) {
                    ForEach(MessageDensity.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }
}
