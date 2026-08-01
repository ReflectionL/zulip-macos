import SwiftUI
import UniformTypeIdentifiers
import ZulipCoreBindings

struct ConversationSurface: View {
    let page: ConversationPage
    var isOffline = false
    var isLoadingEarlier = false
    var reconnect: () -> Void = {}
    var loadEarlier: (() -> Void)?
    var submitMessage: ((String) -> Bool)?
    var openSearch: (() -> Void)?
    var renameTopic: (() -> Void)?
    var moveMessage: ((MessageViewData) -> Void)?
    var editMessage: ((MessageViewData, String) -> Bool)?
    var deleteMessage: ((MessageViewData) -> Bool)?
    var reactToMessage: ((MessageViewData) -> Bool)?
    var starMessage: ((MessageViewData) -> Bool)?
    var setMessageRead: ((MessageViewData, Bool) -> Bool)?
    var retryMessageAction: ((MessageViewData) -> Void)?
    var retrySend: ((MessageViewData) -> Void)?
    var attachmentUploadState = AttachmentUploadState.idle
    var attachmentInsertion: ComposerAttachmentInsertion?
    var uploadAttachment: ((URL) -> Void)?
    var retryAttachmentUpload: (() -> Void)?
    var consumeAttachmentInsertion: ((UInt64) -> Void)?
    var mediaLocalURLs: [String: String] = [:]
    var mediaFailures: [String: String] = [:]
    var requestMedia: ((String) -> Void)?
    var retryMedia: ((String) -> Void)?

    @State private var messages: [MessageViewData]
    @State private var draft = ""
    @State private var followsNewest = true
    @State private var editingMessage: MessageViewData?
    @State private var deletingMessage: MessageViewData?
    @State private var isChoosingAttachment = false
    @FocusState private var isComposerFocused: Bool

    init(
        page: ConversationPage,
        isOffline: Bool = false,
        isLoadingEarlier: Bool = false,
        reconnect: @escaping () -> Void = {},
        loadEarlier: (() -> Void)? = nil,
        submitMessage: ((String) -> Bool)? = nil,
        openSearch: (() -> Void)? = nil,
        renameTopic: (() -> Void)? = nil,
        moveMessage: ((MessageViewData) -> Void)? = nil,
        editMessage: ((MessageViewData, String) -> Bool)? = nil,
        deleteMessage: ((MessageViewData) -> Bool)? = nil,
        reactToMessage: ((MessageViewData) -> Bool)? = nil,
        starMessage: ((MessageViewData) -> Bool)? = nil,
        setMessageRead: ((MessageViewData, Bool) -> Bool)? = nil,
        retryMessageAction: ((MessageViewData) -> Void)? = nil,
        retrySend: ((MessageViewData) -> Void)? = nil,
        attachmentUploadState: AttachmentUploadState = .idle,
        attachmentInsertion: ComposerAttachmentInsertion? = nil,
        uploadAttachment: ((URL) -> Void)? = nil,
        retryAttachmentUpload: (() -> Void)? = nil,
        consumeAttachmentInsertion: ((UInt64) -> Void)? = nil,
        mediaLocalURLs: [String: String] = [:],
        mediaFailures: [String: String] = [:],
        requestMedia: ((String) -> Void)? = nil,
        retryMedia: ((String) -> Void)? = nil
    ) {
        self.page = page
        self.isOffline = isOffline
        self.isLoadingEarlier = isLoadingEarlier
        self.reconnect = reconnect
        self.loadEarlier = loadEarlier
        self.submitMessage = submitMessage
        self.openSearch = openSearch
        self.renameTopic = renameTopic
        self.moveMessage = moveMessage
        self.editMessage = editMessage
        self.deleteMessage = deleteMessage
        self.reactToMessage = reactToMessage
        self.starMessage = starMessage
        self.setMessageRead = setMessageRead
        self.retryMessageAction = retryMessageAction
        self.retrySend = retrySend
        self.attachmentUploadState = attachmentUploadState
        self.attachmentInsertion = attachmentInsertion
        self.uploadAttachment = uploadAttachment
        self.retryAttachmentUpload = retryAttachmentUpload
        self.consumeAttachmentInsertion = consumeAttachmentInsertion
        self.mediaLocalURLs = mediaLocalURLs
        self.mediaFailures = mediaFailures
        self.requestMedia = requestMedia
        self.retryMedia = retryMedia
        _messages = State(initialValue: page.messages)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isOffline {
                HStack(spacing: AppTheme.Spacing.small) {
                    Image(systemName: "wifi.slash")
                    Text("Offline — showing cached messages")
                    Spacer()
                    Button("Reconnect", action: reconnect)
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                }
                .font(AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .padding(.horizontal, AppTheme.Spacing.large)
                .frame(height: 34)
                .background(AppTheme.Colors.warning.opacity(0.12))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Offline, showing cached messages")
            }

            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if page.beforeCursor != nil {
                                Button {
                                    loadEarlier?()
                                } label: {
                                    if isLoadingEarlier {
                                        HStack(spacing: AppTheme.Spacing.small) {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Loading earlier messages…")
                                        }
                                    } else {
                                        Text("Load earlier messages")
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(isLoadingEarlier || loadEarlier == nil)
                                .font(AppTheme.Typography.metadata)
                                .foregroundStyle(AppTheme.Colors.secondaryText)
                                .padding(.vertical, AppTheme.Spacing.large)
                            }

                            ForEach(messages) { message in
                                MessageRow(
                                    message: message,
                                    isFocusedSearchResult: page.focusedMessageID == message.id,
                                    toggleReaction: {
                                        if let reactToMessage {
                                            _ = reactToMessage(message)
                                        } else {
                                            toggleReaction(for: message.id)
                                        }
                                    },
                                    toggleStar: {
                                        if let starMessage {
                                            _ = starMessage(message)
                                        } else {
                                            toggleStar(for: message.id)
                                        }
                                    },
                                    moveToTopic: message.sourceStreamID == nil
                                        ? nil
                                        : { moveMessage?(message) },
                                    edit: message.isOwnMessage && editMessage != nil
                                        ? { editingMessage = message }
                                        : nil,
                                    delete: message.isOwnMessage && deleteMessage != nil
                                        ? { deletingMessage = message }
                                        : nil,
                                    toggleRead: setMessageRead == nil
                                        ? nil
                                        : { _ = setMessageRead?(message, !message.isRead) },
                                    retryAction: {
                                        retryMessageAction?(message)
                                    },
                                    retrySend: {
                                        retrySend?(message)
                                    },
                                    mediaLocalURLs: mediaLocalURLs,
                                    mediaFailures: mediaFailures,
                                    requestMedia: requestMedia,
                                    retryMedia: retryMedia
                                )
                                .id(message.id)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(TimelineAnchor.bottom)
                        }
                        .frame(maxWidth: AppTheme.Metrics.messageMaximumWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, AppTheme.Spacing.extraLarge)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        let remaining = geometry.contentSize.height
                            - geometry.contentOffset.y
                            - geometry.containerSize.height
                        return remaining < 72
                    } action: { _, isAtBottom in
                        followsNewest = isAtBottom
                    }
                    .task(
                        id: TimelineFocus(
                            key: page.key,
                            messageID: page.focusedMessageID
                        )
                    ) {
                        await Task.yield()
                        if let messageID = page.focusedMessageID,
                           messages.contains(where: { $0.id == messageID })
                        {
                            followsNewest = false
                            proxy.scrollTo(messageID, anchor: .center)
                        } else {
                            followsNewest = true
                            proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
                        }
                    }
                    .onChange(of: messages.count) {
                        guard followsNewest else {
                            return
                        }
                        withAnimation(.snappy) {
                            proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
                        }
                    }

                    if !followsNewest {
                        Button {
                            withAnimation(.snappy) {
                                proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
                            }
                        } label: {
                            Label("Jump to latest", systemImage: "arrow.down")
                                .labelStyle(.iconOnly)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .elevatedSurface(radius: 16)
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        .padding(AppTheme.Spacing.large)
                        .help("Jump to latest")
                        .accessibilityLabel("Jump to latest message")
                    }
                }
            }

            ComposerView(
                conversationTitle: page.title,
                draft: $draft,
                isFocused: $isComposerFocused,
                isDisabled: isOffline,
                attachmentUploadState: attachmentUploadState,
                chooseAttachment: uploadAttachment == nil
                    ? nil
                    : { isChoosingAttachment = true },
                retryAttachmentUpload: retryAttachmentUpload,
                send: sendDraft
            )
        }
        .background(AppTheme.Colors.canvas)
        .conversationToolbar(
            title: page.title,
            subtitle: page.subtitle,
            isOffline: isOffline,
            openSearch: openSearch,
            renameTopic: renameTopic
        )
        .overlay {
            Button("Focus message composer") {
                isComposerFocused = true
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onChange(of: page.messages) {
            messages = page.messages
        }
        .task(id: attachmentInsertion?.id) {
            insertAttachmentIfReady()
        }
        .fileImporter(
            isPresented: $isChoosingAttachment,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result,
                  let url = urls.first
            else { return }
            uploadAttachment?(url)
        }
        .sheet(item: $editingMessage) { message in
            EditMessageSheet(message: message) { content in
                if editMessage?(message, content) == true {
                    editingMessage = nil
                }
            }
        }
        .confirmationDialog(
            "Permanently delete this message?",
            isPresented: Binding(
                get: { deletingMessage != nil },
                set: { if !$0 { deletingMessage = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete message", role: .destructive) {
                if let message = deletingMessage {
                    _ = deleteMessage?(message)
                }
                deletingMessage = nil
            }
            Button("Cancel", role: .cancel) {
                deletingMessage = nil
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func toggleReaction(for messageID: Int64) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        messages[index].reactionCount = messages[index].reactionCount == 0 ? 1 : 0
    }

    private func toggleStar(for messageID: Int64) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        messages[index].isStarred.toggle()
    }

    private func sendDraft() {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return
        }

        guard submitMessage?(content) ?? true else {
            return
        }
        let nextID = submitMessage == nil
            ? (messages.last?.id ?? 0) + 1
            : min(messages.last?.id ?? 0, 0) - 1
        if submitMessage == nil {
            messages.append(
            MessageViewData(
                id: nextID,
                accountID: page.key.accountID,
                conversationKey: page.key,
                senderID: 42,
                senderName: "Hua Hai",
                senderInitials: "HH",
                timestamp: .now,
                content: [.paragraph([.text(content)])],
                isOwnMessage: true,
                deliveryState: .sent
            )
            )
        }
        draft = ""
        followsNewest = true
    }

    private func insertAttachmentIfReady() {
        guard let attachmentInsertion,
              attachmentInsertion.key == page.key
        else { return }
        if !draft.isEmpty, draft.last?.isWhitespace == false {
            draft.append("\n")
        }
        draft.append(attachmentInsertion.markdown)
        consumeAttachmentInsertion?(attachmentInsertion.id)
        isComposerFocused = true
    }
}

private enum TimelineAnchor: Hashable {
    case bottom
}

private struct TimelineFocus: Hashable {
    let key: ConversationKey
    let messageID: Int64?
}

extension View {
    func conversationToolbar(
        title: String,
        subtitle: String,
        isOffline: Bool,
        openSearch: (() -> Void)? = nil,
        renameTopic: (() -> Void)? = nil
    ) -> some View {
        modifier(
            ConversationToolbarModifier(
                title: title,
                subtitle: subtitle,
                isOffline: isOffline,
                openSearch: openSearch,
                renameTopic: renameTopic
            )
        )
    }
}

private struct ConversationToolbarModifier: ViewModifier {
    let title: String
    let subtitle: String
    let isOffline: Bool
    let openSearch: (() -> Void)?
    let renameTopic: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: AppTheme.Spacing.small) {
                        Text(subtitle)
                            .foregroundStyle(AppTheme.Colors.secondaryText)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(AppTheme.Colors.tertiaryText)

                        Text(title)
                            .fontWeight(.semibold)
                            .foregroundStyle(AppTheme.Colors.primaryText)
                    }
                    .font(AppTheme.Typography.body)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(subtitle), \(title)\(isOffline ? ", offline" : "")"
                    )
                }
                .sharedBackgroundVisibility(.hidden)

                ToolbarSpacer(.flexible)

                ToolbarItemGroup(placement: .primaryAction) {
                    if isOffline {
                        Label("Offline", systemImage: "wifi.slash")
                            .font(AppTheme.Typography.metadata)
                            .foregroundStyle(AppTheme.Colors.warning)
                            .padding(.horizontal, AppTheme.Spacing.small)
                            .frame(height: 24)
                            .background(AppTheme.Colors.warning.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    if let openSearch {
                        Button(action: openSearch) {
                            Image(systemName: "magnifyingglass")
                        }
                        .help("Search messages")
                        .accessibilityLabel("Search messages")
                    }

                    if let renameTopic {
                        Menu {
                            Button("Rename topic…", action: renameTopic)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuIndicator(.hidden)
                        .help("Topic actions")
                        .accessibilityLabel("Topic actions")
                    }

                    Button {
                        // Conversation details arrive with live membership data.
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .help("Conversation details")
                    .accessibilityLabel("Conversation details")
                }
            }
    }
}

private struct MessageRow: View {
    let message: MessageViewData
    let isFocusedSearchResult: Bool
    let toggleReaction: () -> Void
    let toggleStar: () -> Void
    let moveToTopic: (() -> Void)?
    let edit: (() -> Void)?
    let delete: (() -> Void)?
    let toggleRead: (() -> Void)?
    let retryAction: () -> Void
    let retrySend: () -> Void
    let mediaLocalURLs: [String: String]
    let mediaFailures: [String: String]
    let requestMedia: ((String) -> Void)?
    let retryMedia: ((String) -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.medium) {
            Text(message.senderInitials)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(AppTheme.Colors.hover)
                .clipShape(Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.extraSmall) {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.small) {
                    Text(message.senderName)
                        .font(AppTheme.Typography.bodyEmphasized)

                    Text(message.timestamp, style: .time)
                        .font(AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Colors.tertiaryText)

                    if message.deliveryState == .pending {
                        Text("Sending…")
                            .font(AppTheme.Typography.metadata)
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                    } else if message.deliveryState == .failed {
                        Text("Failed")
                            .font(AppTheme.Typography.metadata)
                            .foregroundStyle(AppTheme.Colors.destructive)
                    }

                    switch message.actionState {
                    case let .pending(kind):
                        Text(pendingLabel(kind))
                            .font(AppTheme.Typography.metadata)
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                    case .failed:
                        Text("Action failed")
                            .font(AppTheme.Typography.metadata)
                            .foregroundStyle(AppTheme.Colors.destructive)
                    case .idle:
                        EmptyView()
                    }
                }

                MessageContentView(
                    blocks: message.content,
                    mediaLocalURLs: mediaLocalURLs,
                    mediaFailures: mediaFailures,
                    requestMedia: requestMedia,
                    retryMedia: retryMedia
                )

                if message.reactionCount > 0 {
                    Button(action: toggleReaction) {
                        Text("👍 \(message.reactionCount)")
                            .font(AppTheme.Typography.metadata)
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .background(AppTheme.Colors.hover)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Thumbs up, \(message.reactionCount) reactions")
                }

                if message.deliveryState == .failed {
                    Button("Retry send", action: retrySend)
                        .buttonStyle(.borderless)
                        .font(AppTheme.Typography.metadata)
                } else if case let .failed(_, failure) = message.actionState {
                    HStack(spacing: AppTheme.Spacing.small) {
                        Text(failure)
                            .lineLimit(1)
                            .foregroundStyle(AppTheme.Colors.destructive)
                        Button("Retry", action: retryAction)
                            .buttonStyle(.borderless)
                    }
                    .font(AppTheme.Typography.metadata)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.medium)
        .padding(.vertical, AppTheme.Spacing.small)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(
                cornerRadius: AppTheme.Metrics.controlRadius,
                style: .continuous
            )
            .fill(
                isFocusedSearchResult
                    ? AppTheme.Colors.accent.opacity(0.12)
                    : isHovered
                        ? AppTheme.Colors.hover.opacity(0.45)
                        : .clear
            )
        }
        .overlay {
            if isFocusedSearchResult {
                RoundedRectangle(
                    cornerRadius: AppTheme.Metrics.controlRadius,
                    style: .continuous
                )
                .stroke(AppTheme.Colors.accent.opacity(0.7), lineWidth: 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            MessageActions(
                isStarred: message.isStarred,
                toggleReaction: toggleReaction,
                toggleStar: toggleStar,
                moveToTopic: moveToTopic,
                edit: edit,
                delete: delete,
                toggleRead: toggleRead,
                isRead: message.isRead,
                isDisabled: message.actionState.isPending || message.deliveryState != .sent
            )
            .padding(.top, 4)
            .padding(.trailing, AppTheme.Spacing.small)
            .opacity(isHovered ? 1 : 0)
            .accessibilityHidden(!isHovered)
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(message.senderName), \(message.plainText)")
        .accessibilityHint(isFocusedSearchResult ? "Selected search result" : "")
        .accessibilityAction(named: "React") {
            toggleReaction()
        }
        .accessibilityAction(named: message.isStarred ? "Unstar" : "Star") {
            toggleStar()
        }
        .accessibilityActions {
            if let edit {
                Button("Edit message", action: edit)
            }
            if let delete {
                Button("Delete message", action: delete)
            }
            if let toggleRead {
                Button(message.isRead ? "Mark unread" : "Mark read", action: toggleRead)
            }
        }
    }

    private func pendingLabel(_ kind: MessageActionKind) -> String {
        switch kind {
        case .edit: "Editing…"
        case .delete: "Deleting…"
        case .reaction: "Updating reaction…"
        case .star: "Updating star…"
        case .readState: "Updating read state…"
        }
    }
}

private struct MessageActions: View {
    let isStarred: Bool
    let toggleReaction: () -> Void
    let toggleStar: () -> Void
    let moveToTopic: (() -> Void)?
    let edit: (() -> Void)?
    let delete: (() -> Void)?
    let toggleRead: (() -> Void)?
    let isRead: Bool
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 0) {
            actionButton(
                title: "React",
                systemImage: "face.smiling",
                action: toggleReaction
            )
            actionButton(
                title: isStarred ? "Unstar" : "Star",
                systemImage: isStarred ? "star.fill" : "star",
                action: toggleStar
            )
            Menu {
                Button("Reply") {}
                Button("Copy link") {}
                if let edit {
                    Divider()
                    Button("Edit message…", action: edit)
                }
                if let moveToTopic {
                    Divider()
                    Button("Move to topic…", action: moveToTopic)
                }
                if let toggleRead {
                    Button(isRead ? "Mark unread" : "Mark read", action: toggleRead)
                }
                if let delete {
                    Divider()
                    Button("Delete message…", role: .destructive, action: delete)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("More actions")
            .accessibilityLabel("More message actions")
            .disabled(isDisabled)
        }
        .elevatedSurface(radius: AppTheme.Metrics.controlRadius)
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

private extension MessageActionState {
    var isPending: Bool {
        if case .pending = self {
            return true
        }
        return false
    }
}

private struct EditMessageSheet: View {
    let message: MessageViewData
    let save: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content: String

    init(message: MessageViewData, save: @escaping (String) -> Void) {
        self.message = message
        self.save = save
        _content = State(initialValue: message.plainText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.large) {
            Text("Edit message")
                .font(AppTheme.Typography.title)
            TextEditor(text: $content)
                .font(AppTheme.Typography.body)
                .frame(minHeight: 140)
                .padding(AppTheme.Spacing.small)
                .background(AppTheme.Colors.hover.opacity(0.45))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppTheme.Metrics.controlRadius,
                        style: .continuous
                    )
                )
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    save(content)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppTheme.Spacing.extraLarge)
        .frame(width: 480)
    }
}

private struct ComposerView: View {
    let conversationTitle: String
    @Binding var draft: String
    var isFocused: FocusState<Bool>.Binding
    let isDisabled: Bool
    let attachmentUploadState: AttachmentUploadState
    let chooseAttachment: (() -> Void)?
    let retryAttachmentUpload: (() -> Void)?
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            switch attachmentUploadState {
            case .idle:
                EmptyView()
            case let .uploading(filename):
                HStack(spacing: AppTheme.Spacing.small) {
                    ProgressView().controlSize(.small)
                    Text("Uploading \(filename)…")
                        .lineLimit(1)
                }
                .font(AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Colors.secondaryText)
            case let .failed(filename, message):
                HStack(spacing: AppTheme.Spacing.small) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("\(filename): \(message)")
                        .lineLimit(1)
                    if let retryAttachmentUpload {
                        Button("Retry", action: retryAttachmentUpload)
                            .buttonStyle(.borderless)
                    }
                }
                .font(AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Colors.destructive)
            }

            TextField(
                "Message \(conversationTitle)",
                text: $draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(AppTheme.Typography.body)
            .lineLimit(1...6)
            .focused(isFocused)
            .disabled(isDisabled)
            .onSubmit(send)
            .onExitCommand {
                isFocused.wrappedValue = false
            }
            .accessibilityLabel("Message \(conversationTitle)")
            .accessibilityHint(
                isDisabled
                    ? "Reconnect to send messages"
                    : "Type a message and press Return to send"
            )

            HStack(spacing: AppTheme.Spacing.small) {
                Button {
                    chooseAttachment?()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(
                    isDisabled
                        || chooseAttachment == nil
                        || attachmentUploadState.isUploading
                )
                .help("Add attachment")
                .accessibilityLabel("Add attachment")

                Button {} label: {
                    Image(systemName: "face.smiling")
                }
                .help("Add emoji")
                .accessibilityLabel("Add emoji")

                Spacer()

                Text("Return to send")
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Colors.tertiaryText)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Colors.canvas)
                .background(
                    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? AppTheme.Colors.tertiaryText
                        : AppTheme.Colors.accent
                )
                .clipShape(Circle())
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send message")
                .accessibilityLabel("Send message")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.Colors.secondaryText)
        }
        .padding(AppTheme.Spacing.medium)
        .frame(maxWidth: AppTheme.Metrics.composerMaximumWidth)
        .elevatedSurface(radius: AppTheme.Metrics.panelRadius)
        .padding(.horizontal, AppTheme.Spacing.extraLarge)
        .padding(.vertical, AppTheme.Spacing.medium)
        .opacity(isDisabled ? 0.62 : 1)
    }
}

#Preview("Conversation surface") {
    ConversationSurface(
        page: FixtureConversation.page(
            for: FixtureSidebar.defaultSelection,
            messageCount: 30
        )
    )
    .frame(width: 800, height: 720)
}
