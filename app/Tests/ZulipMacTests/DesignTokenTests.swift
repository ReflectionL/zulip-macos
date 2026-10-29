import Foundation
import Testing
@testable import ZulipMac

@Suite("Design tokens")
struct DesignTokenTests {
    @Test("Sidebar sizing remains internally consistent")
    func sidebarSizing() {
        #expect(AppTheme.Metrics.sidebarMinimum < AppTheme.Metrics.sidebarIdeal)
        #expect(AppTheme.Metrics.sidebarIdeal < AppTheme.Metrics.sidebarMaximum)
        #expect(AppTheme.Metrics.minimumWindowWidth > AppTheme.Metrics.sidebarMaximum)
        #expect(AppTheme.Metrics.sidebarTopInset == AppTheme.Spacing.small)
    }

    @Test("Spacing follows a monotonic scale")
    func spacingScale() {
        let values = [
            AppTheme.Spacing.extraExtraSmall,
            AppTheme.Spacing.extraSmall,
            AppTheme.Spacing.small,
            AppTheme.Spacing.medium,
            AppTheme.Spacing.large,
            AppTheme.Spacing.extraLarge,
            AppTheme.Spacing.section,
        ]

        #expect(zip(values, values.dropFirst()).allSatisfy(<))
    }

    @Test("Corner radii and control heights follow monotonic scales")
    func radiusAndHeightScales() {
        let radii = [
            AppTheme.Radius.extraSmall,
            AppTheme.Radius.small,
            AppTheme.Radius.medium,
            AppTheme.Radius.large,
        ]
        let heights = [
            AppTheme.ControlHeight.compact,
            AppTheme.ControlHeight.regular,
            AppTheme.ControlHeight.row,
            AppTheme.ControlHeight.bar,
        ]

        #expect(zip(radii, radii.dropFirst()).allSatisfy(<))
        #expect(zip(heights, heights.dropFirst()).allSatisfy(<))
    }

    @Test("Message content stays wider than the composer")
    func contentWidths() {
        #expect(AppTheme.Metrics.messageMaximumWidth <= AppTheme.Metrics.composerMaximumWidth)
    }

    @Test("Every sender color is legible on the canvas in light and dark appearance")
    func senderColorContrast() {
        #expect(SenderColor.hexPairs.count == SenderColor.palette.count)
        for pair in SenderColor.hexPairs {
            #expect(contrast(pair.light, Self.lightCanvas) >= 4.5)
            #expect(contrast(pair.dark, Self.darkCanvas) >= 4.5)
        }
    }

    @Test("Channel colors are read from the server's hex value")
    func channelColorParsing() {
        #expect(ChannelColor.rgb(fromHex: "#76ce90") == 0x76CE90)
        #expect(ChannelColor.rgb(fromHex: "A6C7E5") == 0xA6C7E5)
        #expect(ChannelColor.rgb(fromHex: "not a color") == 0x808080)
    }

    @Test("Normalized channel colors keep their hue and stay visible on the sidebar")
    func channelColorNormalization() {
        for hex in Self.zulipDefaultChannelColors {
            let original = OKLCHColor(rgb: hex)
            let light = ChannelColor.normalized(hex, dark: false)
            let dark = ChannelColor.normalized(hex, dark: true)

            #expect(contrast(light, Self.lightSidebar) >= 3)
            #expect(contrast(dark, Self.darkSidebar) >= 4.5)
            #expect(abs(OKLCHColor(rgb: light).lightness - ChannelColor.lightLightness) < 0.01)
            #expect(OKLCHColor(rgb: light).chroma <= ChannelColor.maximumChroma + 0.01)
            if original.chroma > 0.03 {
                let drift = abs(OKLCHColor(rgb: light).hue - original.hue)
                #expect(min(drift, 360 - drift) < 3)
            }
        }

        // A gray channel stays gray.
        let gray = ChannelColor.normalized(0xC2C2C2, dark: false)
        #expect((gray >> 16) & 0xFF == gray & 0xFF)
    }

    private static let lightCanvas: UInt32 = 0xFFFFFF
    private static let darkCanvas: UInt32 = 0x1C1C1F
    /// Approximations of the translucent sidebar's color.
    private static let lightSidebar: UInt32 = 0xF1F1F4
    private static let darkSidebar: UInt32 = 0x232326

    /// The colors Zulip assigns to new channel subscriptions.
    private static let zulipDefaultChannelColors: [UInt32] = [
        0x76CE90, 0xFAE589, 0xA6C7E5, 0xE79AB5, 0xBFD56F, 0xF4AE55,
        0xB0A5FD, 0xADDFE5, 0xF5CE6E, 0xC2726A, 0x94C849, 0xBD86E5,
        0xEE7E4A, 0xA6DCBF, 0x95A5FD, 0x53A063, 0x9987E1, 0xE4523D,
        0xC2C2C2, 0x4F8DE4, 0xC6A8AD, 0xE7CC4D, 0xC8BEBF, 0xA47462,
    ]

    /// The WCAG contrast ratio between two sRGB colors.
    private func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func relativeLuminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((rgb >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}
