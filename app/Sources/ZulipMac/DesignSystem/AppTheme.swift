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
        static let hairline: CGFloat = 1
        /// Vertical padding around a message row: a message that continues a block,
        /// and the first message of a block (more space above it than below).
        static let continuationInset: CGFloat = 4
        static let blockTopInset: CGFloat = 16
        static let blockBottomInset: CGFloat = 4
        /// How far a topic row is indented under its channel, the width of the
        /// channel's disclosure chevron.
        static let topicIndent: CGFloat = 24
    }

    /// Four corner radii. A shape nested in another uses the outer radius minus
    /// the padding between them, and never less than `extraSmall`.
    enum Radius {
        /// Inline code, key caps, skeleton bars.
        static let extraSmall: CGFloat = 4
        /// Small icon buttons, emoji cells, suggestion rows.
        static let small: CGFloat = 6
        /// Rows, code blocks, quotes, tables, the message action bar.
        static let medium: CGFloat = 10
        /// The composer, pictures, link cards, floating panels.
        static let large: CGFloat = 14
    }

    /// Heights of controls and bars.
    enum ControlHeight {
        static let compact: CGFloat = 24
        static let regular: CGFloat = 28
        static let row: CGFloat = 32
        static let bar: CGFloat = 52
    }

    enum Spacing {
        static let extraExtraSmall: CGFloat = 2
        static let extraSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let extraLarge: CGFloat = 24
        static let section: CGFloat = 32
    }

    /// Fonts follow the user's text-size preference (`InterfaceScale`). Three
    /// weights only: regular, medium and semibold. Text is never smaller than
    /// `caption`; smaller sizes are for SF Symbols.
    @MainActor
    enum Typography {
        /// The welcome title and a message's first-level heading.
        static var display: Font { scaled(20, weight: .semibold) }
        /// A message's second-level heading.
        static var headline: Font { scaled(17, weight: .semibold) }
        /// The conversation title, sheet titles, a third-level heading.
        static var title: Font { scaled(15, weight: .semibold) }
        static var body: Font { scaled(14) }
        static var bodyStrong: Font { scaled(14, weight: .semibold) }
        /// Sidebar rows and the quick switcher.
        static var callout: Font { scaled(13) }
        static var calloutMedium: Font { scaled(13, weight: .medium) }
        /// A sender's name, and a sidebar row with unread messages.
        static var calloutStrong: Font { scaled(13, weight: .semibold) }
        /// Section titles and small buttons.
        static var label: Font { scaled(12, weight: .medium) }
        /// Times, counts, notes and secondary lines.
        static var caption: Font { scaled(11) }
        static var captionStrong: Font { scaled(11, weight: .semibold) }
        static var code: Font { scaled(13, design: .monospaced) }

        /// Extra space between the lines of message text, so wrapped Chinese and
        /// English paragraphs do not sit too tightly.
        static var bodyLineSpacing: CGFloat { 3 * InterfaceScale.shared.factor }

        /// A system font of `size` points at the user's current text size.
        static func scaled(
            _ size: CGFloat,
            weight: Font.Weight = .regular,
            design: Font.Design = .default
        ) -> Font {
            .system(size: size * InterfaceScale.shared.factor, weight: weight, design: design)
        }
    }

    /// The app's own palette, a light and a dark value for each token. One
    /// indigo accent; neutral surfaces, fills and text in fixed steps whose
    /// contrast against the canvas is checked by `DesignTokenTests`.
    enum Colors {
        static let canvas = Color.dynamic(light: 0xFFFFFF, dark: 0x1C1C1F)
        /// The composer, the action bar and floating panels; in dark appearance
        /// lighter than the canvas, because shadows barely show there.
        static let surfaceRaised = Color.dynamic(light: 0xFFFFFF, dark: 0x26262A)
        /// A quiet fill for recessed content such as code blocks, quotes and link cards.
        static let surfaceSunken = Color.dynamic(light: 0xF5F5F7, dark: 0x151517)
        static let fillHover = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.06)
        static let fillPressed = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.10)
        static let stroke = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.09)
        static let strokeStrong = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.16)
        static let primaryText = Color.dynamic(light: 0x1D1D1F, dark: 0xF2F2F4)
        static let secondaryText = Color.dynamic(light: 0x5E5E66, dark: 0xA3A3AB)
        static let tertiaryText = Color.dynamic(light: 0x6A6A73, dark: 0x8A8A93)
        /// Filled accent: the send button, the window tint, the welcome icon.
        static let accent = Color.dynamic(light: 0x4553D0, dark: 0x5F6BE8)
        /// Accent for text and thin marks on the canvas: links, mentions, quote bars.
        static let accentText = Color.dynamic(light: 0x4553D0, dark: 0x8C95FF)
        /// The selected row, the user's own reactions, a focused search result.
        static let accentSoft = Color.dynamic(light: 0x4553D0, dark: 0x8C95FF, lightAlpha: 0.12, darkAlpha: 0.18)
        /// The outline drawn around something marked with `accentSoft`.
        static let accentOutline = Color.dynamic(light: 0x4553D0, dark: 0x8C95FF, lightAlpha: 0.5, darkAlpha: 0.5)
        static let success = Color.dynamic(light: 0x1A7F45, dark: 0x5FCB8E)
        static let warning = Color.dynamic(light: 0xA5600B, dark: 0xE5A64B)
        static let destructive = Color.dynamic(light: 0xC4313B, dark: 0xFF7A7A)
        /// Disabled controls are drawn at this opacity.
        static let disabledOpacity: Double = 0.45
    }

    /// Three animation durations and one curve, plus a spring for things that
    /// travel. Nothing bounces.
    enum Motion {
        /// Press feedback.
        static var instant: Animation { .easeOut(duration: 0.08) }
        /// Hover, controls that appear on hover, color changes.
        static var fast: Animation { .timingCurve(0.2, 0, 0, 1, duration: 0.12) }
        /// Expanding and collapsing, panels appearing, the sidebar.
        static var base: Animation { .timingCurve(0.2, 0, 0, 1, duration: 0.2) }
        /// Scrolling to the newest message and larger travels.
        static var slow: Animation { .snappy(duration: 0.32, extraBounce: 0) }
    }
}

extension Color {
    /// A color that resolves to `light` in light appearance and `dark` in dark
    /// appearance (sRGB hex values such as `0x4553D0`).
    static func dynamic(
        light: UInt32,
        dark: UInt32,
        lightAlpha: Double = 1,
        darkAlpha: Double = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.srgb(hex: dark, alpha: darkAlpha)
                : NSColor.srgb(hex: light, alpha: lightAlpha)
        })
    }
}

extension NSColor {
    static func srgb(hex: UInt32, alpha: Double = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}

/// How far a surface stands off the canvas.
enum SurfaceElevation {
    /// The composer, the message action bar, the jump-to-latest button.
    case raised
    /// The quick switcher, message search and other floating panels.
    case overlay
}

struct ElevatedSurface: ViewModifier {
    var radius = AppTheme.Radius.large
    var elevation = SurfaceElevation.raised
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(AppTheme.Colors.surfaceRaised)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(AppTheme.Colors.stroke, lineWidth: AppTheme.Metrics.hairline)
            }
            // A tight contact shadow and a soft ambient one, stronger in dark
            // appearance, where they fall on a dark canvas.
            .shadow(
                color: .black.opacity(
                    elevation == .raised ? (isDark ? 0.20 : 0.06) : (isDark ? 0.30 : 0.08)
                ),
                radius: elevation == .raised ? 1 : 3,
                y: elevation == .raised ? 1 : 2
            )
            .shadow(
                color: .black.opacity(
                    elevation == .raised ? (isDark ? 0.25 : 0.06) : (isDark ? 0.45 : 0.18)
                ),
                radius: elevation == .raised ? 6 : 20,
                y: elevation == .raised ? 4 : 16
            )
    }
}

extension View {
    func elevatedSurface(
        radius: CGFloat = AppTheme.Radius.large,
        elevation: SurfaceElevation = .raised
    ) -> some View {
        modifier(ElevatedSurface(radius: radius, elevation: elevation))
    }

    /// Animates changes of `value`, or applies them at once when the user has
    /// turned on Reduce Motion. Use it for changes that move or scale something;
    /// plain fades may keep their animation.
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(ReducibleAnimation(animation: animation, value: value))
    }
}

private struct ReducibleAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

#if DEBUG
private struct DesignTokenPreview: View {
    private let swatches: [(String, Color)] = [
        ("Canvas", AppTheme.Colors.canvas),
        ("Raised", AppTheme.Colors.surfaceRaised),
        ("Sunken", AppTheme.Colors.surfaceSunken),
        ("Hover", AppTheme.Colors.fillHover),
        ("Accent soft", AppTheme.Colors.accentSoft),
        ("Accent", AppTheme.Colors.accent),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.large) {
            Text("Zulip Mac design tokens")
                .font(AppTheme.Typography.title)

            ForEach(swatches, id: \.0) { name, color in
                HStack {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
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
