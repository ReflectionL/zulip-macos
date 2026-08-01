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
            AppTheme.Spacing.extraSmall,
            AppTheme.Spacing.small,
            AppTheme.Spacing.medium,
            AppTheme.Spacing.large,
            AppTheme.Spacing.extraLarge,
            AppTheme.Spacing.section,
        ]

        #expect(zip(values, values.dropFirst()).allSatisfy(<))
    }

    @Test("Message content stays wider than the composer")
    func contentWidths() {
        #expect(AppTheme.Metrics.messageMaximumWidth <= AppTheme.Metrics.composerMaximumWidth)
    }
}
