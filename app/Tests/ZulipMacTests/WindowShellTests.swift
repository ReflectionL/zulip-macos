import AppKit
import Testing
@testable import ZulipMac

@Suite("Window shell")
@MainActor
struct WindowShellTests {
    @Test("Only the native sidebar toggle is suppressed")
    func nativeSidebarTogglePolicy() {
        let nativeToggle = NSToolbarItem(itemIdentifier: .toggleSidebar)
        let customControl = NSToolbarItem(
            itemIdentifier: .init("io.github.huahai.ZulipMac.sidebarControl")
        )

        #expect(NativeToolbarItemPolicy.shouldHide(nativeToggle))
        #expect(!NativeToolbarItemPolicy.shouldHide(customControl))
    }
}
