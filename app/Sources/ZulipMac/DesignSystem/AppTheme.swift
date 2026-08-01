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
        static let controlRadius: CGFloat = 8
        static let panelRadius: CGFloat = 12
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

    enum Colors {
        static let canvas = Color(
            light: NSColor(srgbRed: 0.985, green: 0.982, blue: 0.974, alpha: 1),
            dark: NSColor(srgbRed: 0.075, green: 0.075, blue: 0.078, alpha: 1)
        )
        static let sidebar = Color(
            light: NSColor(srgbRed: 0.955, green: 0.949, blue: 0.936, alpha: 1),
            dark: NSColor(srgbRed: 0.105, green: 0.105, blue: 0.110, alpha: 1)
        )
        static let elevated = Color(
            light: NSColor(srgbRed: 1, green: 0.998, blue: 0.992, alpha: 1),
            dark: NSColor(srgbRed: 0.125, green: 0.125, blue: 0.132, alpha: 1)
        )
        static let hover = Color(
            light: NSColor(srgbRed: 0.90, green: 0.89, blue: 0.87, alpha: 0.66),
            dark: NSColor(srgbRed: 0.21, green: 0.21, blue: 0.22, alpha: 0.72)
        )
        static let selection = Color(
            light: NSColor(srgbRed: 0.86, green: 0.86, blue: 0.84, alpha: 0.82),
            dark: NSColor(srgbRed: 0.25, green: 0.25, blue: 0.27, alpha: 0.82)
        )
        static let subtleStroke = Color(
            light: NSColor.black.withAlphaComponent(0.10),
            dark: NSColor.white.withAlphaComponent(0.10)
        )
        static let primaryText = Color(nsColor: .labelColor)
        static let secondaryText = Color(nsColor: .secondaryLabelColor)
        static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
        static let accent = Color(
            light: NSColor(srgbRed: 0.29, green: 0.33, blue: 0.30, alpha: 1),
            dark: NSColor(srgbRed: 0.71, green: 0.75, blue: 0.69, alpha: 1)
        )
        static let success = Color(
            light: NSColor(srgbRed: 0.12, green: 0.50, blue: 0.30, alpha: 1),
            dark: NSColor(srgbRed: 0.38, green: 0.78, blue: 0.55, alpha: 1)
        )
        static let warning = Color(
            light: NSColor(srgbRed: 0.72, green: 0.42, blue: 0.10, alpha: 1),
            dark: NSColor(srgbRed: 0.92, green: 0.66, blue: 0.30, alpha: 1)
        )
        static let destructive = Color(nsColor: .systemRed)
        static let focus = Color(nsColor: .keyboardFocusIndicatorColor)
    }
}

private extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? dark
                    : light
            }
        )
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
