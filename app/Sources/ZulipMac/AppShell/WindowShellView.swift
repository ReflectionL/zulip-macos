import AppKit
import SwiftUI
import ZulipCoreBindings

struct WindowShellView<Sidebar: View, Content: View>: View {
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private let sidebar: Sidebar
    private let content: Content

    init(
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder content: () -> Content
    ) {
        self.sidebar = sidebar()
        self.content = content()
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: AppTheme.Metrics.sidebarMinimum,
                    ideal: AppTheme.Metrics.sidebarIdeal,
                    max: AppTheme.Metrics.sidebarMaximum
                )
                .background(AppTheme.Colors.sidebar)
        } detail: {
            content
                .background(AppTheme.Colors.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: AppTheme.Metrics.minimumWindowWidth,
            minHeight: AppTheme.Metrics.minimumWindowHeight
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SidebarToggleButton(
                    isSidebarVisible: columnVisibility != .detailOnly
                ) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        columnVisibility = columnVisibility == .detailOnly
                            ? .all
                            : .detailOnly
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .background {
            NativeSidebarToggleHider()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

private struct SidebarToggleButton: View {
    let isSidebarVisible: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var label: String {
        isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? AppTheme.Colors.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .keyboardShortcut("s", modifiers: [.command, .control])
        .onHover { isHovered = $0 }
    }
}

private struct NativeSidebarToggleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ToolbarSidebarToggleHidingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ToolbarSidebarToggleHidingView)?.hideNativeToggleSoon()
    }
}

// NavigationSplitView re-inserts its default toolbar toggle on macOS 26 even
// when SwiftUI's toolbar-removal modifier is present, so suppress that one
// public AppKit item after toolbar resolution and keep our flat control.
private final class ToolbarSidebarToggleHidingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideNativeToggleSoon()
    }

    func hideNativeToggleSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.hideNativeToggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.hideNativeToggle()
            }
        }
    }

    private func hideNativeToggle() {
        guard let toolbar = window?.toolbar else { return }
        toolbar.items
            .filter(NativeToolbarItemPolicy.shouldHide)
            .forEach { $0.isHidden = true }
    }
}

@MainActor
enum NativeToolbarItemPolicy {
    static func shouldHide(_ item: NSToolbarItem) -> Bool {
        let identifier = item.itemIdentifier.rawValue.lowercased()
        let action = item.action.map(NSStringFromSelector)?.lowercased() ?? ""
        return item.itemIdentifier == .toggleSidebar
            || identifier.contains("togglesidebar")
            || action.contains("togglesidebar")
    }
}

private struct PrototypeContent: View {
    let navigation: NavigationStore

    var body: some View {
        ConversationStateContainer(key: navigation.selection)
        .id(navigation.selection)
    }
}

struct PrototypeWindowView: View {
    var connectToZulip: (() -> Void)?

    @State private var sidebarModel = SidebarViewModel(snapshot: FixtureSidebar.snapshot)
    @State private var navigation = NavigationStore(
        directory: FixtureNavigation.directory,
        initialSelection: FixtureSidebar.defaultSelection
    )

    var body: some View {
        ZStack(alignment: .top) {
            WindowShellView {
                SidebarView(
                    model: sidebarModel,
                    selection: Binding(
                        get: { navigation.selection },
                        set: { selection in
                            navigation.select(selection)
                        }
                    ),
                    openCommandPalette: {
                        navigation.presentCommandPalette()
                    },
                    sessionControl: connectToZulip.map { connectToZulip in
                        SidebarSessionControl(
                            action: .connect,
                            perform: connectToZulip
                        )
                    }
                )
            } content: {
                PrototypeContent(navigation: navigation)
            }

            if navigation.isCommandPalettePresented {
                AppTheme.Colors.canvas
                    .opacity(0.58)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        navigation.dismissCommandPalette()
                    }

                CommandPaletteView(navigation: navigation)
                    .padding(.top, 74)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Button("Open quick switcher") {
                navigation.presentCommandPalette()
            }
            .keyboardShortcut("k", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
        }
        .animation(.snappy(duration: 0.2), value: navigation.isCommandPalettePresented)
        .onChange(of: navigation.selection) {
            navigation.dismissCommandPalette()
        }
    }
}


#Preview("Window — standard") {
    PrototypeWindowView()
        .frame(width: 1_080, height: 720)
}

#Preview("Window — compact") {
    PrototypeWindowView()
        .frame(
            width: AppTheme.Metrics.minimumWindowWidth,
            height: AppTheme.Metrics.minimumWindowHeight
        )
}
