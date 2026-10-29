import SwiftUI

/// A button that lights up under the pointer and darkens while pressed, for
/// small controls without chrome of their own. The fill lies over the label,
/// so it also shows on a label with its own background, such as a chip.
struct HoverFillButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = AppTheme.Radius.small

    func makeBody(configuration: Configuration) -> some View {
        HoverFillButton(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct HoverFillButton: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        private var fill: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return AppTheme.Colors.fillPressed }
            return isHovered ? AppTheme.Colors.fillHover : .clear
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .overlay(shape.fill(fill).allowsHitTesting(false))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : AppTheme.Colors.disabledOpacity)
                .onHover { isHovered = $0 }
                .animation(AppTheme.Motion.fast, value: isHovered)
                .animation(AppTheme.Motion.instant, value: configuration.isPressed)
        }
    }
}
