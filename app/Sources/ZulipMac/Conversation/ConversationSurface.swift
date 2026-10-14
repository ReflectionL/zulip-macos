import AppKit
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
    var renameChannel: (() -> Void)?
    var openParent: (() -> Void)?
    var headerStatus: String?
    var composerHint: String?
    var moveMessage: ((MessageViewData) -> Void)?
    var editMessage: ((MessageViewData, String) -> Bool)?
    var deleteMessage: ((MessageViewData) -> Bool)?
    var reactToMessage: ((MessageViewData, ReactionTarget) -> Bool)?
    var starMessage: ((MessageViewData) -> Bool)?
    var setMessageRead: ((MessageViewData, Bool) -> Bool)?
    var retryMessageAction: ((MessageViewData) -> Void)?
    var retrySend: ((MessageViewData) -> Void)?
    var quoteMessage: ((MessageViewData) -> Void)?
    var forwardMessage: ((MessageViewData, ConversationKey) -> Void)?
    var forwardDestinations: ((String) -> [NavigationDestination])?
    var mentionCandidates: [MentionCandidate] = []
    var attachmentUploadState = AttachmentUploadState.idle
    var attachmentInsertion: ComposerAttachmentInsertion?
    var uploadAttachment: ((URL) -> Void)?
    /// Files dropped onto the conversation; the first uploads now, the rest queue.
    var uploadDroppedFiles: (([URL]) -> Void)?
    var retryAttachmentUpload: (() -> Void)?
    var consumeAttachmentInsertion: ((UInt64) -> Void)?
    var mediaLocalURLs: [String: String] = [:]
    var mediaFailures: [String: String] = [:]
    var requestMedia: ((String) -> Void)?
    var retryMedia: ((String) -> Void)?
    var initialDraft = ""
    var draftChanged: ((String) -> Void)?
    /// Who is typing in this conversation, ready to show above the composer.
    var typingDescription: String?
    /// Reports whether the user is typing (true) or stopped (false).
    var typingChanged: ((Bool) -> Void)?
    var readReceipts: ReadReceiptDisplay?
    /// Asks the core who has read the given message; returns whether to keep asking.
    var pollReadReceipts: ((Int64) -> Bool)?

    @State private var messages: [MessageViewData]
    @State private var draft = ""
    @State private var followsNewest = true
    @State private var editingMessage: MessageViewData?
    @State private var deletingMessage: MessageViewData?
    @State private var forwardingMessage: MessageViewData?
    @State private var pendingQuote: ComposerQuote?
    @State private var isChoosingAttachment = false
    @State private var isDropTargeted = false
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
        renameChannel: (() -> Void)? = nil,
        openParent: (() -> Void)? = nil,
        headerStatus: String? = nil,
        composerHint: String? = nil,
        moveMessage: ((MessageViewData) -> Void)? = nil,
        editMessage: ((MessageViewData, String) -> Bool)? = nil,
        deleteMessage: ((MessageViewData) -> Bool)? = nil,
        reactToMessage: ((MessageViewData, ReactionTarget) -> Bool)? = nil,
        starMessage: ((MessageViewData) -> Bool)? = nil,
        setMessageRead: ((MessageViewData, Bool) -> Bool)? = nil,
        retryMessageAction: ((MessageViewData) -> Void)? = nil,
        retrySend: ((MessageViewData) -> Void)? = nil,
        quoteMessage: ((MessageViewData) -> Void)? = nil,
        forwardMessage: ((MessageViewData, ConversationKey) -> Void)? = nil,
        forwardDestinations: ((String) -> [NavigationDestination])? = nil,
        mentionCandidates: [MentionCandidate] = [],
        attachmentUploadState: AttachmentUploadState = .idle,
        attachmentInsertion: ComposerAttachmentInsertion? = nil,
        uploadAttachment: ((URL) -> Void)? = nil,
        uploadDroppedFiles: (([URL]) -> Void)? = nil,
        retryAttachmentUpload: (() -> Void)? = nil,
        consumeAttachmentInsertion: ((UInt64) -> Void)? = nil,
        mediaLocalURLs: [String: String] = [:],
        mediaFailures: [String: String] = [:],
        requestMedia: ((String) -> Void)? = nil,
        retryMedia: ((String) -> Void)? = nil,
        initialDraft: String = "",
        draftChanged: ((String) -> Void)? = nil,
        typingDescription: String? = nil,
        typingChanged: ((Bool) -> Void)? = nil,
        readReceipts: ReadReceiptDisplay? = nil,
        pollReadReceipts: ((Int64) -> Bool)? = nil
    ) {
        self.page = page
        self.isOffline = isOffline
        self.isLoadingEarlier = isLoadingEarlier
        self.reconnect = reconnect
        self.loadEarlier = loadEarlier
        self.submitMessage = submitMessage
        self.openSearch = openSearch
        self.renameTopic = renameTopic
        self.renameChannel = renameChannel
        self.openParent = openParent
        self.headerStatus = headerStatus
        self.composerHint = composerHint
        self.moveMessage = moveMessage
        self.editMessage = editMessage
        self.deleteMessage = deleteMessage
        self.reactToMessage = reactToMessage
        self.starMessage = starMessage
        self.setMessageRead = setMessageRead
        self.retryMessageAction = retryMessageAction
        self.retrySend = retrySend
        self.quoteMessage = quoteMessage
        self.forwardMessage = forwardMessage
        self.forwardDestinations = forwardDestinations
        self.mentionCandidates = mentionCandidates
        self.attachmentUploadState = attachmentUploadState
        self.attachmentInsertion = attachmentInsertion
        self.uploadAttachment = uploadAttachment
        self.uploadDroppedFiles = uploadDroppedFiles
        self.retryAttachmentUpload = retryAttachmentUpload
        self.consumeAttachmentInsertion = consumeAttachmentInsertion
        self.mediaLocalURLs = mediaLocalURLs
        self.mediaFailures = mediaFailures
        self.requestMedia = requestMedia
        self.retryMedia = retryMedia
        self.initialDraft = initialDraft
        self.draftChanged = draftChanged
        self.typingDescription = typingDescription
        self.typingChanged = typingChanged
        self.readReceipts = readReceipts
        self.pollReadReceipts = pollReadReceipts
        _messages = State(initialValue: page.messages)
        _draft = State(initialValue: initialDraft)
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

                            let continuations = MessageGrouping.continuationIDs(in: messages)
                            ForEach(messages, id: \.rowID) { message in
                                MessageRow(
                                    message: message,
                                    isContinuation: continuations.contains(message.id),
                                    isFocusedSearchResult: page.focusedMessageID == message.id,
                                    react: { target in
                                        if let reactToMessage {
                                            _ = reactToMessage(message, target)
                                        } else {
                                            toggleReaction(target, for: message.id)
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
                                    quote: quoteMessage == nil
                                        ? nil
                                        : { quoteMessage?(message) },
                                    forward: forwardMessage == nil || forwardDestinations == nil
                                        ? nil
                                        : { forwardingMessage = message },
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
                                    retryMedia: retryMedia,
                                    readers: readReceipts?.messageID == message.id
                                        ? readReceipts?.readers ?? []
                                        : []
                                )
                                .id(message.rowID)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(TimelineAnchor.bottom)
                        }
                        .frame(maxWidth: AppTheme.Metrics.messageMaximumWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, AppTheme.Spacing.extraLarge)
                    }
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
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
                            proxy.scrollTo(rowID(for: messageID), anchor: .center)
                        } else {
                            followsNewest = true
                            proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
                        }
                    }
                    .onChange(of: messages.count) {
                        guard followsNewest else {
                            return
                        }
                        proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
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
                hint: composerHint,
                draft: $draft,
                isFocused: $isComposerFocused,
                isDisabled: isOffline,
                quote: pendingQuote,
                clearQuote: { pendingQuote = nil },
                mentionCandidates: mentionCandidates,
                attachmentUploadState: attachmentUploadState,
                chooseAttachment: uploadAttachment == nil
                    ? nil
                    : { isChoosingAttachment = true },
                retryAttachmentUpload: retryAttachmentUpload,
                send: sendDraft
            )
            .overlay(alignment: .topLeading) {
                if let typingDescription {
                    TypingIndicator(text: typingDescription)
                        .alignmentGuide(.top) { $0[.bottom] }
                        .padding(.leading, AppTheme.Spacing.large)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: typingDescription)
        }
        .background(AppTheme.Colors.canvas)
        .dropDestination(for: URL.self) { urls, _ in
            guard let uploadDroppedFiles, !isOffline, !urls.isEmpty else {
                return false
            }
            uploadDroppedFiles(urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted && uploadDroppedFiles != nil && !isOffline
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay {
                        Label("Drop to upload", systemImage: "arrow.up.doc")
                            .font(.headline)
                            .padding(AppTheme.Spacing.large)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(AppTheme.Spacing.small)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        .conversationToolbar(
            title: page.title,
            subtitle: page.subtitle,
            isOffline: isOffline,
            status: headerStatus,
            openParent: openParent,
            openSearch: openSearch,
            renameTopic: renameTopic,
            renameChannel: renameChannel
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
        .task(
            id: ReadReceiptPolling(key: page.key, messageID: readReceipts?.messageID)
        ) {
            guard let messageID = readReceipts?.messageID, let pollReadReceipts else {
                return
            }
            var attempt = 0
            while !Task.isCancelled, pollReadReceipts(messageID) {
                try? await Task.sleep(for: ReadReceiptPolicy.delay(afterAttempt: attempt))
                attempt += 1
            }
        }
        .onChange(of: page.messages) {
            messages = page.messages
        }
        .onChange(of: draft) {
            draftChanged?(draft)
            // Text restored from a saved draft is not typing; only the focused
            // composer announces it, and emptying the box always withdraws it.
            if draft.isEmpty || isComposerFocused {
                typingChanged?(!draft.isEmpty)
            }
        }
        .onChange(of: page.key) {
            pendingQuote = nil
        }
        .onChange(of: initialDraft) {
            // Persisted drafts can arrive after the surface appears.
            if draft.isEmpty {
                draft = initialDraft
            }
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
        .sheet(item: $forwardingMessage) { message in
            if let forwardDestinations {
                ForwardMessageSheet(
                    message: message,
                    destinations: forwardDestinations
                ) { key in
                    forwardMessage?(message, key)
                    forwardingMessage = nil
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

    /// The timeline row that shows a message; a sent message can keep its echo's row.
    private func rowID(for messageID: Int64) -> Int64 {
        messages.first(where: { $0.id == messageID })?.rowID ?? messageID
    }

    private func toggleReaction(_ target: ReactionTarget, for messageID: Int64) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        let add = messages[index].reaction(matching: target)?.includesMe != true
        messages[index].applyReaction(target, add: add)
    }

    private func toggleStar(for messageID: Int64) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        messages[index].isStarred.toggle()
    }

    private func sendDraft() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = [pendingQuote?.markdown, typed.isEmpty ? nil : typed]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        guard !content.isEmpty else {
            return
        }

        guard submitMessage?(content) ?? true else {
            return
        }
        pendingQuote = nil
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
        if let quote = attachmentInsertion.quote {
            pendingQuote = quote
            consumeAttachmentInsertion?(attachmentInsertion.id)
            isComposerFocused = true
            return
        }
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
        status: String? = nil,
        openParent: (() -> Void)? = nil,
        openSearch: (() -> Void)? = nil,
        renameTopic: (() -> Void)? = nil,
        renameChannel: (() -> Void)? = nil
    ) -> some View {
        modifier(
            ConversationToolbarModifier(
                title: title,
                subtitle: subtitle,
                isOffline: isOffline,
                status: status,
                openParent: openParent,
                openSearch: openSearch,
                renameTopic: renameTopic,
                renameChannel: renameChannel
            )
        )
    }
}

private struct ConversationToolbarModifier: ViewModifier {
    let title: String
    let subtitle: String
    let isOffline: Bool
    let status: String?
    let openParent: (() -> Void)?
    let openSearch: (() -> Void)?
    let renameTopic: (() -> Void)?
    let renameChannel: (() -> Void)?

    private var accessibilitySummary: String {
        var parts = [subtitle, title]
        if let status {
            parts.append(status)
        }
        if isOffline {
            parts.append("offline")
        }
        return parts.joined(separator: ", ")
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: AppTheme.Spacing.small) {
                        if let openParent {
                            Button(action: openParent) {
                                Text(subtitle)
                                    .foregroundStyle(AppTheme.Colors.secondaryText)
                            }
                            .buttonStyle(.plain)
                            .help("Open \(subtitle)")
                            .accessibilityLabel("Open \(subtitle)")
                        } else {
                            Text(subtitle)
                                .foregroundStyle(AppTheme.Colors.secondaryText)
                        }

                        Image(systemName: "chevron.right")
                            .font(AppTheme.Typography.scaled(9, weight: .semibold))
                            .foregroundStyle(AppTheme.Colors.tertiaryText)

                        Text(title)
                            .fontWeight(.semibold)
                            .foregroundStyle(AppTheme.Colors.primaryText)

                        if let status {
                            Text(status)
                                .font(AppTheme.Typography.metadata)
                                .foregroundStyle(AppTheme.Colors.tertiaryText)
                        }
                    }
                    .font(AppTheme.Typography.body)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(accessibilitySummary)
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

                    if renameTopic != nil || renameChannel != nil {
                        Menu {
                            if let renameTopic {
                                Button("Rename topic…", action: renameTopic)
                            }
                            if let renameChannel {
                                Button("Rename channel…", action: renameChannel)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuIndicator(.hidden)
                        .help("Conversation actions")
                        .accessibilityLabel("Conversation actions")
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

/// Restarts read-receipt polling when the conversation or its newest sent message changes.
private struct ReadReceiptPolling: Hashable {
    let key: ConversationKey
    let messageID: Int64?
}

private struct MessageRow: View {
    let message: MessageViewData
    let isContinuation: Bool
    let isFocusedSearchResult: Bool
    let react: (ReactionTarget) -> Void
    let toggleStar: () -> Void
    let moveToTopic: (() -> Void)?
    let edit: (() -> Void)?
    let delete: (() -> Void)?
    let quote: (() -> Void)?
    let forward: (() -> Void)?
    let toggleRead: (() -> Void)?
    let retryAction: () -> Void
    let retrySend: () -> Void
    let mediaLocalURLs: [String: String]
    let mediaFailures: [String: String]
    let requestMedia: ((String) -> Void)?
    let retryMedia: ((String) -> Void)?
    var readers: [ReadReceiptReader] = []

    @State private var isHovered = false
    @State private var isPickingReaction = false

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.medium) {
            if isContinuation {
                Text(message.timestamp, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                    .font(AppTheme.Typography.scaled(9).monospacedDigit())
                    .foregroundStyle(AppTheme.Colors.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: Self.avatarSize, alignment: .center)
                    .padding(.top, 3)
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(true)
            } else {
                AvatarImage(
                    initials: message.senderInitials,
                    remoteURL: message.senderAvatarURL,
                    size: Self.avatarSize,
                    mediaLocalURLs: mediaLocalURLs,
                    requestMedia: requestMedia
                )
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.extraSmall) {
                if isContinuation {
                    if hasStatus {
                        HStack(spacing: AppTheme.Spacing.small) {
                            statusLabels
                        }
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.small) {
                        Text(message.senderName)
                            .font(AppTheme.Typography.bodyEmphasized)

                        Text(MessageTimestamp.format(message.timestamp))
                            .font(AppTheme.Typography.metadata)
                            .foregroundStyle(AppTheme.Colors.tertiaryText)
                            .help(message.timestamp.formatted(date: .complete, time: .standard))

                        statusLabels
                    }
                }

                if !showsPlaceholder {
                    MessageContentView(
                        blocks: message.content,
                        mediaLocalURLs: mediaLocalURLs,
                        mediaFailures: mediaFailures,
                        requestMedia: requestMedia,
                        retryMedia: retryMedia
                    )
                }

                if let editedAt = message.editedAt, !showsPlaceholder {
                    Text("(edited)")
                        .font(AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                        .help("Edited \(editedAt.formatted(date: .abbreviated, time: .shortened))")
                }

                if !message.reactions.isEmpty {
                    ReactionChips(
                        reactions: message.reactions,
                        isDisabled: message.actionState.isPending || message.deliveryState != .sent,
                        react: react
                    )
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

                if !readers.isEmpty {
                    ReadReceiptStack(
                        readers: readers,
                        mediaLocalURLs: mediaLocalURLs,
                        requestMedia: requestMedia
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)
                }
            }
            .animation(.snappy, value: readers)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.medium)
        .padding(
            .top,
            isContinuation
                ? AppTheme.Metrics.continuationInset
                : AppTheme.Metrics.blockTopInset
        )
        .padding(
            .bottom,
            isContinuation
                ? AppTheme.Metrics.continuationInset
                : AppTheme.Metrics.blockBottomInset
        )
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
                isPickingReaction: $isPickingReaction,
                reactions: message.reactions,
                react: react,
                toggleStar: toggleStar,
                moveToTopic: moveToTopic,
                edit: edit,
                delete: delete,
                quote: quote,
                forward: forward,
                toggleRead: toggleRead,
                isRead: message.isRead,
                isDisabled: message.actionState.isPending || message.deliveryState != .sent
            )
            .padding(.top, 4)
            .padding(.trailing, AppTheme.Spacing.small)
            .opacity(isHovered || isPickingReaction ? 1 : 0)
            .accessibilityHidden(!isHovered && !isPickingReaction)
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(message.senderName), \(message.plainText)")
        .accessibilityHint(isFocusedSearchResult ? "Selected search result" : "")
        .accessibilityAction(named: "React") {
            isPickingReaction = true
        }
        .accessibilityAction(named: message.isStarred ? "Unstar" : "Star") {
            toggleStar()
        }
        .accessibilityActions {
            if let quote {
                Button("Quote and reply", action: quote)
            }
            if let forward {
                Button("Forward message", action: forward)
            }
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

    private static let avatarSize: CGFloat = 32

    /// A just-sent Markdown message waits for its server rendering instead of showing
    /// its raw source, which would flash when the rendered copy replaces it.
    private var showsPlaceholder: Bool {
        message.isProvisional && message.deliveryState != .failed
    }

    private var hasStatus: Bool {
        message.deliveryState != .sent || message.actionState != .idle || showsPlaceholder
    }

    @ViewBuilder
    private var statusLabels: some View {
        if message.deliveryState == .pending || showsPlaceholder {
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
    @Binding var isPickingReaction: Bool
    let reactions: [MessageReaction]
    let react: (ReactionTarget) -> Void
    let toggleStar: () -> Void
    let moveToTopic: (() -> Void)?
    let edit: (() -> Void)?
    let delete: (() -> Void)?
    let quote: (() -> Void)?
    let forward: (() -> Void)?
    let toggleRead: (() -> Void)?
    let isRead: Bool
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 0) {
            actionButton(
                title: "React",
                systemImage: "face.smiling",
                action: { isPickingReaction = true }
            )
            .popover(isPresented: $isPickingReaction, arrowEdge: .bottom) {
                ReactionPicker(existing: reactions) { target in
                    isPickingReaction = false
                    react(target)
                }
            }
            actionButton(
                title: isStarred ? "Unstar" : "Star",
                systemImage: isStarred ? "star.fill" : "star",
                action: toggleStar
            )
            if let quote {
                actionButton(
                    title: "Quote and reply",
                    systemImage: "quote.bubble",
                    action: quote
                )
            }
            Menu {
                if let quote {
                    Button("Quote and reply", action: quote)
                }
                if let forward {
                    Button("Forward message…", action: forward)
                }
                if let edit {
                    if quote != nil || forward != nil {
                        Divider()
                    }
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

private struct ForwardMessageSheet: View {
    let message: MessageViewData
    let destinations: (String) -> [NavigationDestination]
    let choose: (ConversationKey) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
            Text("Forward message")
                .font(AppTheme.Typography.title)
            Text("\(message.senderName): \(message.plainText)")
                .font(AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .lineLimit(2)
            TextField("Search topics and people", text: $query)
                .textFieldStyle(.roundedBorder)
            List(destinations(query)) { destination in
                Button {
                    choose(destination.key)
                } label: {
                    HStack {
                        Image(systemName: destination.systemImage)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(destination.title)
                            Text(destination.subtitle)
                                .font(AppTheme.Typography.metadata)
                                .foregroundStyle(AppTheme.Colors.secondaryText)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(AppTheme.Spacing.large)
        .frame(width: 420)
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
    let hint: String?
    @Binding var draft: String
    var isFocused: FocusState<Bool>.Binding
    let isDisabled: Bool
    let quote: ComposerQuote?
    let clearQuote: () -> Void
    let mentionCandidates: [MentionCandidate]
    let attachmentUploadState: AttachmentUploadState
    let chooseAttachment: (() -> Void)?
    let retryAttachmentUpload: (() -> Void)?
    let send: () -> Void

    @State private var selection: TextSelection?
    @State private var mentionIndex = 0
    @State private var dismissedMentionDraft: String?
    @State private var pendingCaretOffset: Int?

    /// The selection clamped to the current draft. `selection` can lag behind
    /// `draft` (after a send clears it, a conversation switch or a programmatic
    /// edit), and a stale index used for a mutation traps.
    private var selectedRange: Range<String.Index> {
        guard let selection, case let .selection(range) = selection.indices else {
            return draft.endIndex..<draft.endIndex
        }
        let lower = min(max(range.lowerBound, draft.startIndex), draft.endIndex)
        let upper = min(max(range.upperBound, lower), draft.endIndex)
        return lower..<upper
    }

    private var caret: String.Index {
        selectedRange.upperBound
    }

    /// The `@` being typed with its matching people, if any.
    private var mentionMatch: (trigger: MentionAutocomplete.Trigger, items: [MentionCandidate])? {
        guard !isDisabled,
              !mentionCandidates.isEmpty,
              draft != dismissedMentionDraft,
              let trigger = MentionAutocomplete.trigger(in: draft, caret: caret)
        else {
            return nil
        }
        let items = MentionAutocomplete.suggestions(mentionCandidates, query: trigger.query)
        return items.isEmpty ? nil : (trigger, items)
    }

    private func acceptMention(
        _ candidate: MentionCandidate,
        trigger shownTrigger: MentionAutocomplete.Trigger
    ) {
        // Finish any input-method composition first: replacing text while the field
        // still holds marked text is what made clicking a suggestion crash.
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.unmarkText()

        // The suggestion list was built from an earlier draft, so find the `@`
        // again in the current text instead of reusing its stored indices.
        guard let trigger = MentionAutocomplete.trigger(in: draft, caret: caret) else {
            return
        }
        let text = MentionAutocomplete.replacement(
            for: candidate,
            isSilent: shownTrigger.isSilent,
            among: mentionCandidates
        )
        let offset = draft.distance(from: draft.startIndex, to: trigger.range.lowerBound)
        draft.replaceSubrange(trigger.range, with: text)
        mentionIndex = 0
        // The caret moves once the field has taken the new text.
        pendingCaretOffset = offset + text.count
        isFocused.wrappedValue = true
    }

    /// Puts the caret at `pendingCaretOffset` (clamped to the text) after a
    /// programmatic edit has been applied to the field.
    private func placePendingCaret() {
        guard let offset = pendingCaretOffset else {
            return
        }
        pendingCaretOffset = nil
        let clamped = min(max(offset, 0), draft.count)
        selection = TextSelection(
            insertionPoint: draft.index(draft.startIndex, offsetBy: clamped)
        )
    }

    private func moveMentionSelection(by delta: Int) -> KeyPress.Result {
        guard let match = mentionMatch else {
            return .ignored
        }
        let count = match.items.count
        mentionIndex = (min(mentionIndex, count - 1) + delta + count) % count
        return .handled
    }

    private func acceptHighlightedMention() -> KeyPress.Result {
        guard let match = mentionMatch else {
            return .ignored
        }
        acceptMention(match.items[min(mentionIndex, match.items.count - 1)], trigger: match.trigger)
        return .handled
    }

    @ViewBuilder
    private func mentionList(_ match: (trigger: MentionAutocomplete.Trigger, items: [MentionCandidate])) -> some View {
        let highlighted = min(mentionIndex, match.items.count - 1)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(match.items.enumerated()), id: \.element.id) { index, item in
                Button {
                    acceptMention(item, trigger: match.trigger)
                } label: {
                    HStack(spacing: AppTheme.Spacing.small) {
                        Image(systemName: item.systemImage)
                            .foregroundStyle(AppTheme.Colors.tertiaryText)
                            .frame(width: 18)
                        Text(item.name)
                        Text(item.detail)
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(AppTheme.Typography.body)
                    .padding(.horizontal, AppTheme.Spacing.medium)
                    .padding(.vertical, 5)
                    .background(index == highlighted ? AppTheme.Colors.accent.opacity(0.18) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(AppTheme.Colors.sidebar)
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppTheme.Metrics.controlRadius,
                style: .continuous
            )
        )
        .accessibilityLabel("Mention suggestions")
    }

    private var placeholder: String {
        hint.map { "Message \(conversationTitle) · \($0)" } ?? "Message \(conversationTitle)"
    }

    private var canSend: Bool {
        quote != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Return sends; Shift+Return or Option+Return inserts a line break at the
    /// caret (or replaces the selection).
    ///
    /// The field editor does the insertion itself, so the caret and selection
    /// stay consistent with the text. Writing `draft` and `selection` together
    /// from here made AppKit apply a caret that was past the end of the not yet
    /// updated text, which crashed.
    private func insertLineBreak() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.insertNewlineIgnoringFieldEditor(nil)
            return
        }
        let range = selectedRange
        let offset = draft.distance(from: draft.startIndex, to: range.lowerBound)
        draft.replaceSubrange(range, with: "\n")
        // The caret moves once the field has taken the new text.
        pendingCaretOffset = offset + 1
    }

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

            if let quote {
                HStack(alignment: .top, spacing: AppTheme.Spacing.small) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to \(quote.senderName)")
                            .fontWeight(.medium)
                        Text(quote.snippet)
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button(action: clearQuote) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.Colors.tertiaryText)
                    .help("Remove quote")
                    .accessibilityLabel("Remove quote")
                }
                .font(AppTheme.Typography.metadata)
                .padding(.vertical, AppTheme.Spacing.small)
                .padding(.horizontal, AppTheme.Spacing.medium)
                .background(AppTheme.Colors.sidebar)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppTheme.Metrics.controlRadius,
                        style: .continuous
                    )
                )
            }

            if let match = mentionMatch {
                mentionList(match)
            }

            TextField(
                LocalizedStringKey(placeholder),
                text: $draft,
                selection: $selection,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(AppTheme.Typography.body)
            .lineLimit(1...6)
            .focused(isFocused)
            .disabled(isDisabled)
            .onKeyPress(.upArrow) { moveMentionSelection(by: -1) }
            .onKeyPress(.downArrow) { moveMentionSelection(by: 1) }
            .onKeyPress(.tab) { acceptHighlightedMention() }
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.isEmpty, mentionMatch != nil {
                    return acceptHighlightedMention()
                }
                guard press.modifiers.contains(.shift) || press.modifiers.contains(.option) else {
                    return .ignored
                }
                insertLineBreak()
                return .handled
            }
            .onSubmit(send)
            .onChange(of: draft) {
                mentionIndex = 0
                placePendingCaret()
            }
            .onExitCommand {
                if mentionMatch != nil {
                    dismissedMentionDraft = draft
                } else {
                    isFocused.wrappedValue = false
                }
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

                Spacer()

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(AppTheme.Typography.scaled(12, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(canSend ? AppTheme.Colors.accent : AppTheme.Colors.tertiaryText)
                .clipShape(Circle())
                .disabled(!canSend)
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

/// A small note floating above the composer while someone else is typing.
private struct TypingIndicator: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTheme.Typography.metadata)
            .foregroundStyle(AppTheme.Colors.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, AppTheme.Spacing.medium)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .allowsHitTesting(false)
            .accessibilityLabel(text)
    }
}
