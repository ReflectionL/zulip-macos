import SwiftUI
import ZulipCoreBindings

struct AppRootView: View {
    @State private var session = LiveSessionViewModel(notifier: SystemMessageNotifier())
    @State private var isLoginPresented = false

    var body: some View {
        Group {
            if session.identity != nil, session.sidebarSnapshot != nil {
                LiveWindowView(session: session)
            } else {
                PrototypeWindowView {
                    isLoginPresented = true
                }
            }
        }
        .sheet(isPresented: $isLoginPresented) {
            LiveLoginView(session: session)
        }
        .task {
            session.startObserving()
            await session.restoreSavedSession()
        }
        .onChange(of: session.connectionState) {
            switch session.connectionState {
            case .connected:
                isLoginPresented = false
            case .failed:
                // Surface why the session ended or could not resume.
                isLoginPresented = true
            default:
                break
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

private struct ConnectionStatusPill: View {
    let text: String

    var body: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Colors.secondaryText)
        }
        .padding(.horizontal, AppTheme.Spacing.medium)
        .padding(.vertical, AppTheme.Spacing.small)
        .background(.regularMaterial, in: Capsule())
    }
}

private struct LiveWindowView: View {
    let session: LiveSessionViewModel

    @State private var sidebarModel: SidebarViewModel
    @State private var navigation: NavigationStore
    @State private var isMessageSearchPresented = false
    @State private var suppressedSelectionOpen: ConversationKey?
    @State private var topicSheet: LiveTopicSheetContext?

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
                    openCommandPalette: presentQuickSwitcher,
                    startNewTopic: { channel in
                        if !sidebarModel.isChannelExpanded(channel.streamID) {
                            sidebarModel.toggleChannel(channel.streamID)
                        }
                        topicSheet = .new(channel: channel)
                    },
                    sessionControl: SidebarSessionControl(
                        action: .disconnect,
                        perform: session.disconnect
                    ),
                    mediaLocalURLs: session.mediaLocalURLs,
                    requestMedia: session.loadMedia
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

            if isMessageSearchPresented {
                AppTheme.Colors.canvas
                    .opacity(0.58)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissMessageSearch()
                    }

                MessageSearchView(
                    session: session,
                    openResult: openSearchResult,
                    dismiss: dismissMessageSearch
                )
                .padding(.top, 74)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let statusText = connectionStatusText {
                ConnectionStatusPill(text: statusText)
                    .padding(.top, AppTheme.Spacing.small)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Button("Open quick switcher") {
                presentQuickSwitcher()
            }
            .keyboardShortcut("k", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)

            Button("Search messages") {
                presentMessageSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)

            ForEach(0..<4, id: \.self) { index in
                Button("Go to destination \(index + 1)") {
                    navigation.selectQuickLink(index)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            }

            Button("Previous conversation") {
                navigation.selectRelative(-1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .frame(width: 0, height: 0)
            .opacity(0)

            Button("Next conversation") {
                navigation.selectRelative(1)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .frame(width: 0, height: 0)
            .opacity(0)
        }
        .animation(.snappy(duration: 0.2), value: navigation.isCommandPalettePresented)
        .animation(.snappy(duration: 0.2), value: isMessageSearchPresented)
        .animation(.snappy(duration: 0.2), value: session.connectionState)
        .onChange(of: navigation.selection) {
            navigation.dismissCommandPalette()
            if suppressedSelectionOpen == navigation.selection {
                suppressedSelectionOpen = nil
                return
            }
            session.openConversation(navigation.selection)
        }
        .onChange(of: session.sidebarSnapshot) {
            guard let snapshot = session.sidebarSnapshot else {
                return
            }
            sidebarModel.replaceSnapshot(snapshot)
        }
        .onChange(of: session.navigationDirectory) {
            navigation.replaceDirectory(session.navigationDirectory)
        }
        .onChange(of: session.requestedTopicNavigation) {
            guard let key = session.requestedTopicNavigation,
                  let destination = session.navigationDirectory.destination(for: key)
            else {
                return
            }
            navigation.select(destination)
            session.clearRequestedTopicNavigation()
        }
        .onChange(of: session.topicActionState) {
            if session.topicActionState == .idle,
               topicSheet?.isServerMutation == true
            {
                topicSheet = nil
            }
        }
        .sheet(item: $topicSheet) { context in
            LiveTopicActionSheet(
                session: session,
                context: context,
                beginTopic: beginTopic,
                dismiss: {
                    topicSheet = nil
                }
            )
        }
    }

    private var connectionStatusText: String? {
        // The live window only exists with a session, so `.connecting` here is
        // the cached-data-while-connecting state. Retries are announced by the
        // conversation's own offline banner.
        session.connectionState == .connecting ? "Connecting…" : nil
    }

    @ViewBuilder
    private var liveConversation: some View {
        switch session.conversationState {
        case let .loaded(page):
            ConversationSurface(
                page: page,
                isLoadingEarlier: session.isLoadingOlderMessages,
                loadEarlier: {
                    session.loadOlderMessages(for: page.key)
                },
                submitMessage: { content in
                    session.sendText(content, to: page.key)
                },
                openSearch: presentMessageSearch,
                renameTopic: renameAction(for: page),
                moveMessage: { message in
                    topicSheet = .move(message: message)
                },
                editMessage: { message, content in
                    session.editMessage(message, content: content)
                },
                deleteMessage: { message in
                    session.deleteMessage(message)
                },
                reactToMessage: { message in
                    session.toggleThumbsUp(message)
                },
                starMessage: { message in
                    session.toggleStar(message)
                },
                setMessageRead: { message, read in
                    session.setRead(message, read: read)
                },
                retryMessageAction: { message in
                    session.retryMessageAction(for: message.id)
                },
                retrySend: { message in
                    session.retrySend(message)
                },
                quoteMessage: { message in
                    session.quote(message)
                },
                forwardMessage: { message, key in
                    session.forward(message, to: key)
                },
                forwardDestinations: { query in
                    session.forwardDestinations(matching: query)
                },
                attachmentUploadState: session.attachmentUploadState,
                attachmentInsertion: session.attachmentInsertion,
                uploadAttachment: { url in
                    session.uploadAttachment(url, to: page.key)
                },
                retryAttachmentUpload: session.retryAttachmentUpload,
                consumeAttachmentInsertion: session.consumeAttachmentInsertion,
                mediaLocalURLs: session.mediaLocalURLs,
                mediaFailures: session.mediaFailures,
                requestMedia: session.loadMedia,
                retryMedia: session.retryMedia,
                initialDraft: session.draft(for: page.key),
                draftChanged: { session.updateDraft($0, for: page.key) }
            )
        case let .offline(page):
            ConversationSurface(
                page: page,
                isOffline: true,
                reconnect: session.reconnectNow,
                openSearch: presentMessageSearch,
                initialDraft: session.draft(for: page.key),
                draftChanged: { session.updateDraft($0, for: page.key) }
            )
        case let .loading(title, subtitle):
            DelayedLoadingPlaceholder(title: title, subtitle: subtitle)
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

    private func presentQuickSwitcher() {
        dismissMessageSearch()
        navigation.presentCommandPalette()
    }

    private func presentMessageSearch() {
        navigation.dismissCommandPalette()
        session.clearMessageSearch()
        isMessageSearchPresented = true
    }

    private func dismissMessageSearch() {
        isMessageSearchPresented = false
        session.clearMessageSearch()
    }

    private func openSearchResult(_ result: MessageSearchResult) {
        let changesSelection = navigation.selection != result.conversationKey
        if changesSelection {
            suppressedSelectionOpen = result.conversationKey
        }
        navigation.select(result.navigationDestination)
        session.openSearchResult(result)
        if !changesSelection {
            suppressedSelectionOpen = nil
        }
        isMessageSearchPresented = false
    }

    private func renameAction(for page: ConversationPage) -> (() -> Void)? {
        guard case .topic = page.key,
              let anchor = page.messages.last(where: { $0.id > 0 })?.id
        else {
            return nil
        }
        return {
            topicSheet = .rename(key: page.key, anchorMessageID: anchor)
        }
    }

    private func beginTopic(_ streamID: Int64, _ name: String) {
        guard let key = session.beginNewTopic(streamID: streamID, name: name),
              let destination = session.navigationDirectory.destination(for: key)
        else {
            return
        }
        navigation.select(destination)
        topicSheet = nil
    }
}

private enum LiveTopicSheetContext: Identifiable {
    case new(channel: ChannelSnapshot)
    case rename(key: ConversationKey, anchorMessageID: Int64)
    case move(message: MessageViewData)

    var id: String {
        switch self {
        case let .new(channel):
            "new-\(channel.streamID)"
        case let .rename(key, anchorMessageID):
            "rename-\(key)-\(anchorMessageID)"
        case let .move(message):
            "move-\(message.id)"
        }
    }

    var isServerMutation: Bool {
        switch self {
        case .new:
            false
        case .rename, .move:
            true
        }
    }
}

private struct LiveTopicActionSheet: View {
    @Bindable var session: LiveSessionViewModel
    let context: LiveTopicSheetContext
    let beginTopic: (Int64, String) -> Void
    let dismiss: () -> Void

    @State private var topicName: String

    init(
        session: LiveSessionViewModel,
        context: LiveTopicSheetContext,
        beginTopic: @escaping (Int64, String) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.session = session
        self.context = context
        self.beginTopic = beginTopic
        self.dismiss = dismiss
        switch context {
        case .new:
            _topicName = State(initialValue: "")
        case let .rename(key, _):
            if case let .topic(_, _, topic) = key {
                _topicName = State(initialValue: topic)
            } else {
                _topicName = State(initialValue: "")
            }
        case .move:
            _topicName = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.large) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.extraSmall) {
                Text(title)
                    .font(AppTheme.Typography.title)
                Text(explanation)
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            }

            TextField("Topic name", text: $topicName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            if !suggestions.isEmpty, case .move = context {
                Menu("Choose an existing topic") {
                    ForEach(suggestions) { topic in
                        Button(topic.name.isEmpty ? "(no topic)" : topic.name) {
                            topicName = topic.name
                        }
                    }
                }
            }

            if case let .failed(_, message) = session.topicActionState,
               context.isServerMutation
            {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Colors.destructive)
                Button("Retry last request") {
                    session.retryTopicAction()
                }
            }

            HStack {
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(actionTitle, action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTopic.isEmpty || isWorking)
            }
        }
        .padding(28)
        .frame(width: 440)
        .interactiveDismissDisabled(isWorking)
    }

    private var title: String {
        switch context {
        case let .new(channel):
            "New topic in #\(channel.name)"
        case .rename:
            "Rename topic"
        case .move:
            "Move message to topic"
        }
    }

    private var explanation: String {
        switch context {
        case .new:
            "The topic is created on Zulip when you send its first message."
        case .rename:
            "Every message in the current topic will use the new name."
        case .move:
            "Only this message moves. Enter an existing or new topic name."
        }
    }

    private var actionTitle: String {
        switch context {
        case .new:
            "Start topic"
        case .rename:
            "Rename"
        case .move:
            "Move"
        }
    }

    private var trimmedTopic: String {
        topicName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isWorking: Bool {
        if case .working = session.topicActionState {
            return true
        }
        return false
    }

    private var suggestions: [TopicSnapshot] {
        let streamID: Int64?
        switch context {
        case let .new(channel):
            streamID = channel.streamID
        case let .rename(key, _):
            if case let .topic(_, value, _) = key {
                streamID = value
            } else {
                streamID = nil
            }
        case let .move(message):
            streamID = message.sourceStreamID
        }
        return session.sidebarSnapshot?.channels
            .first(where: { $0.streamID == streamID })?
            .topics
            .filter { $0.name != currentTopic } ?? []
    }

    private var currentTopic: String? {
        switch context {
        case .new:
            nil
        case let .rename(key, _):
            if case let .topic(_, _, topic) = key {
                topic
            } else {
                nil
            }
        case let .move(message):
            message.sourceTopic
        }
    }

    private func submit() {
        switch context {
        case let .new(channel):
            beginTopic(channel.streamID, trimmedTopic)
        case let .rename(key, anchorMessageID):
            _ = session.renameTopic(
                key,
                anchorMessageID: anchorMessageID,
                newName: trimmedTopic
            )
        case let .move(message):
            _ = session.moveMessage(message, to: trimmedTopic)
        }
    }
}

/// Shows a blank canvas first and the loading message only if loading takes
/// longer than a moment, so quick opens never flash a spinner-like placeholder.
private struct DelayedLoadingPlaceholder: View {
    private static let delay: Duration = .milliseconds(400)

    let title: String
    let subtitle: String
    @State private var isVisible = false

    var body: some View {
        Group {
            if isVisible {
                LivePlaceholder(
                    title: title,
                    subtitle: subtitle,
                    symbol: "ellipsis",
                    message: "Loading messages…"
                )
            } else {
                AppTheme.Colors.canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .conversationToolbar(title: title, subtitle: subtitle, isOffline: false)
            }
        }
        .task(id: title + "\u{1F}" + subtitle) {
            isVisible = false
            try? await Task.sleep(for: Self.delay)
            if !Task.isCancelled {
                isVisible = true
            }
        }
    }
}

private struct LivePlaceholder: View {
    let title: String
    let subtitle: String
    let symbol: String
    let message: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: symbol,
            description: Text(message)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Colors.canvas)
        .conversationToolbar(
            title: title,
            subtitle: subtitle,
            isOffline: false
        )
    }
}

#Preview("Live login") {
    LiveLoginView(session: LiveSessionViewModel())
}
