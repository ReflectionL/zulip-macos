import AppKit
import SwiftUI

enum AppTheme {
    enum Metrics {
        static let sidebarMinimum: CGFloat = 240
        static let sidebarIdeal: CGFloat = 272
        static let sidebarMaximum: CGFloat = 320
        static let sidebarTopInset: CGFloat = 8
        static let minimumWindowWidth: CGFloat = 820
        static let minimumWindowHeight: CGFloat = 560
        static let headerHeight: CGFloat = 52
        static let composerMaximumWidth: CGFloat = 880
        static let messageMaximumWidth: CGFloat = 860
        static let controlRadius: CGFloat = 10
        static let panelRadius: CGFloat = 16
        static let hairline: CGFloat = 1
    }

    enum Spacing {
        static let extraSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let extraLarge: CGFloat = 24
        static let section: CGFloat = 32
    }

    enum Typography {
        static let eyebrow = Font.system(size: 11, weight: .semibold)
        static let sidebar = Font.system(size: 13, weight: .regular)
        static let sidebarEmphasized = Font.system(size: 13, weight: .medium)
        static let body = Font.system(size: 14, weight: .regular)
        static let bodyEmphasized = Font.system(size: 14, weight: .semibold)
        static let title = Font.system(size: 15, weight: .semibold)
        static let code = Font.system(size: 13, design: .monospaced)
        static let metadata = Font.system(size: 11, weight: .regular)
    }

    /// Neutral, system-derived colors: surfaces follow the macOS appearance and
    /// the user's accent color, and fills are tints of the label color so they
    /// stay legible on translucent sidebar material in light and dark.
    enum Colors {
        static let canvas = Color(nsColor: .textBackgroundColor)
        /// A quiet fill for recessed content such as code blocks.
        static let sidebar = Color.primary.opacity(0.045)
        static let elevated = Color(nsColor: .controlBackgroundColor)
        static let hover = Color.primary.opacity(0.06)
        static let selection = Color.primary.opacity(0.10)
        static let subtleStroke = Color.primary.opacity(0.08)
        static let primaryText = Color(nsColor: .labelColor)
        static let secondaryText = Color(nsColor: .secondaryLabelColor)
        static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
        static let accent = Color.accentColor
        static let success = Color(nsColor: .systemGreen)
        static let warning = Color(nsColor: .systemOrange)
        static let destructive = Color(nsColor: .systemRed)
        static let focus = Color(nsColor: .keyboardFocusIndicatorColor)
    }
}

struct ElevatedSurface: ViewModifier {
    var radius = AppTheme.Metrics.panelRadius

    func body(content: Content) -> some View {
        content
            .background(AppTheme.Colors.elevated)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(AppTheme.Colors.subtleStroke, lineWidth: AppTheme.Metrics.hairline)
            }
    }
}

extension View {
    func elevatedSurface(radius: CGFloat = AppTheme.Metrics.panelRadius) -> some View {
        modifier(ElevatedSurface(radius: radius))
    }
}

#if DEBUG
private struct DesignTokenPreview: View {
    private let swatches: [(String, Color)] = [
        ("Canvas", AppTheme.Colors.canvas),
        ("Sidebar", AppTheme.Colors.sidebar),
        ("Elevated", AppTheme.Colors.elevated),
        ("Hover", AppTheme.Colors.hover),
        ("Selection", AppTheme.Colors.selection),
        ("Accent", AppTheme.Colors.accent),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.large) {
            Text("Zulip Mac design tokens")
                .font(AppTheme.Typography.title)

            ForEach(swatches, id: \.0) { name, color in
                HStack {
                    RoundedRectangle(cornerRadius: AppTheme.Metrics.controlRadius)
                        .fill(color)
                        .frame(width: 72, height: 36)
                    Text(name)
                        .font(AppTheme.Typography.body)
                }
            }
        }
        .padding(AppTheme.Spacing.extraLarge)
        .background(AppTheme.Colors.canvas)
    }
}

#Preview("Design tokens — light") {
    DesignTokenPreview()
        .preferredColorScheme(.light)
}

#Preview("Design tokens — dark") {
    DesignTokenPreview()
        .preferredColorScheme(.dark)
}
#endif
