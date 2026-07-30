import SwiftUI
import ZulipCoreBindings

struct AppRootView: View {
    @State private var session = LiveSessionViewModel()
    @State private var isLoginPresented = false

    var body: some View {
        Group {
            if session.identity != nil, session.sidebarSnapshot != nil {
                LiveWindowView(session: session)
            } else {
                PrototypeWindowView()
            }
        }
        .toolbar {
            ToolbarItem {
                if session.identity == nil {
                    Button {
                        isLoginPresented = true
                    } label: {
                        Label("Connect to Zulip", systemImage: "bolt.horizontal.circle")
                    }
                    .help("Connect to a live Zulip organization")
                } else {
                    Button {
                        session.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .help("Disconnect the live account")
                }
            }
        }
        .sheet(isPresented: $isLoginPresented) {
            LiveLoginView(session: session)
        }
        .task {
            session.startObserving()
        }
        .onChange(of: session.connectionState) {
            if session.connectionState == .connected {
                isLoginPresented = false
            }
        }
    }
}

struct LiveLoginView: View {
    @Bindable var session: LiveSessionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.extraLarge) {
            HStack {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.extraSmall) {
                    Text("Connect to Zulip")
                        .font(AppTheme.Typography.title)
                    Text("Credentials stay in memory until the API key is saved in Keychain.")
                        .font(AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            Picker("Authentication", selection: $session.authenticationMethod) {
                ForEach(LiveAuthenticationMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)

            Grid(alignment: .leading, horizontalSpacing: AppTheme.Spacing.large) {
                GridRow {
                    Text("Server")
                    TextField("https://your-org.zulipchat.com", text: $session.serverURL)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Email")
                    TextField("you@example.com", text: $session.email)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(session.authenticationMethod.rawValue)
                    SecureField(
                        session.authenticationMethod == .password
                            ? "Password"
                            : "API key",
                        text: $session.secret
                    )
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()
                    .onSubmit {
                        session.connect()
                    }
                }
            }
            .font(AppTheme.Typography.body)

            if let message = statusMessage {
                Label(message, systemImage: statusIcon)
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Use Saved API Key") {
                    Task {
                        await session.connectUsingSavedAPIKey()
                    }
                }
                .disabled(session.connectionState.isConnecting)

                Spacer()

                if session.connectionState.isConnecting {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Connect") {
                    session.connect()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(session.connectionState.isConnecting)
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(AppTheme.Colors.canvas)
        .interactiveDismissDisabled(session.connectionState.isConnecting)
    }

    private var statusMessage: String? {
        switch session.connectionState {
        case let .failed(message):
            message
        case let .retrying(delay):
            "Connection interrupted. Retrying in \(delay) ms."
        default:
            session.notice
        }
    }

    private var statusIcon: String {
        if case .failed = session.connectionState {
            return "exclamationmark.triangle"
        }
        return "info.circle"
    }

    private var statusColor: Color {
        if case .failed = session.connectionState {
            return AppTheme.Colors.destructive
        }
        return AppTheme.Colors.secondaryText
    }
}

private struct LiveWindowView: View {
    let session: LiveSessionViewModel

    @State private var sidebarModel: SidebarViewModel
    @State private var navigation: NavigationStore

    init(session: LiveSessionViewModel) {
        self.session = session
        let sidebar = session.sidebarSnapshot
            ?? SidebarSnapshot(
                accountID: "unavailable",
                organizationName: "Zulip",
                organizationHost: "",
                quickLinks: [],
                channels: [],
                directMessages: [],
                currentUserName: "",
                currentUserInitials: "?"
            )
        _sidebarModel = State(initialValue: SidebarViewModel(snapshot: sidebar))
        _navigation = State(
            initialValue: NavigationStore(
                directory: session.navigationDirectory,
                initialSelection: session.navigationDirectory.destinations.first?.key
                    ?? .inbox(accountID: sidebar.accountID)
            )
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            WindowShellView {
                SidebarView(
                    model: sidebarModel,
                    selection: Binding(
                        get: { navigation.selection },
                        set: { navigation.select($0) }
                    ),
                    openCommandPalette: navigation.presentCommandPalette
                )
            } content: {
                liveConversation
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
            session.openConversation(navigation.selection)
        }
        .onChange(of: session.sidebarSnapshot) {
            guard let snapshot = session.sidebarSnapshot else {
                return
            }
            sidebarModel.snapshot = snapshot
            navigation.replaceDirectory(session.navigationDirectory)
        }
    }

    @ViewBuilder
    private var liveConversation: some View {
        switch session.conversationState {
        case let .loaded(page):
            ConversationSurface(
                page: page,
                submitMessage: { content in
                    session.sendText(content, to: page.key)
                }
            )
        case let .offline(page):
            ConversationSurface(
                page: page,
                isOffline: true,
                reconnect: {
                    session.openConversation(page.key)
                }
            )
        case let .loading(title, subtitle):
            LivePlaceholder(
                title: title,
                subtitle: subtitle,
                symbol: "ellipsis",
                message: "Loading messages…"
            )
        case let .empty(title, subtitle, message):
            LivePlaceholder(
                title: title,
                subtitle: subtitle,
                symbol: "text.bubble",
                message: message
            )
        case let .failure(title, subtitle, message):
            LivePlaceholder(
                title: title,
                subtitle: subtitle,
                symbol: "exclamationmark.triangle",
                message: message
            )
        }
    }
}

private struct LivePlaceholder: View {
    let title: String
    let subtitle: String
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            ConversationPathHeader(title: title, subtitle: subtitle, isOffline: false)
            Divider()
            ContentUnavailableView(
                title,
                systemImage: symbol,
                description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppTheme.Colors.canvas)
    }
}

#Preview("Live login") {
    LiveLoginView(session: LiveSessionViewModel())
}
