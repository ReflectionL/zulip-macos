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
                .ignoresSafeArea(.container, edges: .top)
        } detail: {
            content
                .background(AppTheme.Colors.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: AppTheme.Metrics.minimumWindowWidth,
            minHeight: AppTheme.Metrics.minimumWindowHeight
        )
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
