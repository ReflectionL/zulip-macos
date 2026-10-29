import AppKit
import Combine
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
    var cancelSend: ((MessageViewData) -> Void)?
    var cancelMessageAction: ((MessageViewData) -> Void)?
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
    var dismissAttachmentUploadFailure: (() -> Void)?
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
    /// A sender's status, shown as an emoji after their name.
    var userStatus: ((Int64) -> UserStatusDisplay?)?
    /// Where a message was posted ("#channel › topic"), shown on hover in
    /// timelines that mix topics; nil where the header already names it.
    var sourceLabel: ((MessageViewData) -> String?)?

    @State private var messages: [MessageViewData]
    @State private var draft = ""
    /// Whether a saved draft arriving later may still fill the composer. Cleared
    /// by a send: re-evaluating this view right after submitting can pass the
    /// just-sent text as `initialDraft` again, and restoring it would leave the
    /// sent message in the box.
    @State private var acceptsSavedDraft = true
    @State private var followsNewest = true
    /// How far the toolbar reaches into the timeline's top edge.
    @State private var toolbarInset: CGFloat = 0
    /// How far below the composer's outer top edge the typing line's bottom sits:
    /// just above the composer card, which starts after its own top padding.
    private static let typingIndicatorDrop: CGFloat = 10
    @State private var editingMessage: MessageViewData?
    @State private var deletingMessage: MessageViewData?
    @State private var forwardingMessage: MessageViewData?
    @State private var pendingQuote: ComposerQuote?
    @State private var isChoosingAttachment = false
    @State private var isDropTargeted = false
    /// What "Today" and "Yesterday" are measured from. Refreshed when the day or
    /// the time zone changes and when the app comes back, so an open chat that
    /// stays on screen past midnight does not keep yesterday's labels.
    @State private var labelsReferenceDate = Date.now
    @FocusState private var isComposerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        cancelSend: ((MessageViewData) -> Void)? = nil,
        cancelMessageAction: ((MessageViewData) -> Void)? = nil,
        quoteMessage: ((MessageViewData) -> Void)? = nil,
        forwardMessage: ((MessageViewData, ConversationKey) -> Void)? = nil,
        forwardDestinations: ((String) -> [NavigationDestination])? = nil,
        mentionCandidates: [MentionCandidate] = [],
        attachmentUploadState: AttachmentUploadState = .idle,
        attachmentInsertion: ComposerAttachmentInsertion? = nil,
        uploadAttachment: ((URL) -> Void)? = nil,
        uploadDroppedFiles: (([URL]) -> Void)? = nil,
        retryAttachmentUpload: (() -> Void)? = nil,
        dismissAttachmentUploadFailure: (() -> Void)? = nil,
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
        pollReadReceipts: ((Int64) -> Bool)? = nil,
        userStatus: ((Int64) -> UserStatusDisplay?)? = nil,
        sourceLabel: ((MessageViewData) -> String?)? = nil
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
        self.cancelSend = cancelSend
        self.cancelMessageAction = cancelMessageAction
        self.quoteMessage = quoteMessage
        self.forwardMessage = forwardMessage
        self.forwardDestinations = forwardDestinations
        self.mentionCandidates = mentionCandidates
        self.attachmentUploadState = attachmentUploadState
        self.attachmentInsertion = attachmentInsertion
        self.uploadAttachment = uploadAttachment
        self.uploadDroppedFiles = uploadDroppedFiles
        self.retryAttachmentUpload = retryAttachmentUpload
        self.dismissAttachmentUploadFailure = dismissAttachmentUploadFailure
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
        self.userStatus = userStatus
        self.sourceLabel = sourceLabel
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
                .font(AppTheme.Typography.caption)
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
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Colors.secondaryText)
                                .padding(.vertical, AppTheme.Spacing.large)
                            }

                            let continuations = MessageGrouping.continuationIDs(in: messages)
                            let dayStarts = MessageGrouping.dayStartIDs(in: messages)
                            ForEach(messages, id: \.rowID) { message in
                                VStack(spacing: 0) {
                                    if dayStarts.contains(message.id) {
                                        DateSeparator(date: message.timestamp, now: labelsReferenceDate)
                                    }
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
                                        cancelSend: {
                                            cancelSend?(message)
                                        },
                                        cancelAction: {
                                            cancelMessageAction?(message)
                                        },
                                        mediaLocalURLs: mediaLocalURLs,
                                        mediaFailures: mediaFailures,
                                        requestMedia: requestMedia,
                                        retryMedia: retryMedia,
                                        readers: readReceipts?.messageID == message.id
                                            ? readReceipts?.readers ?? []
                                            : [],
                                        senderStatus: continuations.contains(message.id)
                                            ? nil
                                            : userStatus?(message.senderID),
                                        sourceLabel: continuations.contains(message.id)
                                            ? nil
                                            : sourceLabel?(message)
                                    )
                                }
                                .id(message.rowID)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(TimelineAnchor.bottom)
                        }
                        .frame(maxWidth: AppTheme.Metrics.messageMaximumWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, AppTheme.Spacing.extraLarge)
                        // Keep the first and newest messages clear of the fades
                        // while the timeline is at rest.
                        .padding(.top, TimelineEdgeFade.topClearance)
                        .padding(.bottom, TimelineEdgeFade.bottomLength)
                    }
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    // The window has no title bar, so messages scroll under the
                    // toolbar's breadcrumb; fade them out before they reach it,
                    // and before they meet the composer at the bottom.
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.safeAreaInsets.top
                    } action: { inset in
                        toolbarInset = inset
                    }
                    .mask { TimelineEdgeFade(toolbarInset: toolbarInset) }
                    .onScrollGeometryChange(for: TimelineScrollMetrics.self) { geometry in
                        TimelineScrollMetrics(
                            contentHeight: geometry.contentSize.height,
                            offset: geometry.contentOffset.y,
                            containerHeight: geometry.containerSize.height
                        )
                    } action: { old, new in
                        // Content that grows under a still scroll position (a new
                        // message, a picture that finished loading) is not the
                        // user scrolling away. Judging it by the distance left
                        // used to stop following whenever the new content was
                        // taller than the threshold, before the scroll to the
                        // newest message ran.
                        if new.contentHeight > old.contentHeight,
                           abs(new.offset - old.offset) < 1
                        {
                            if followsNewest {
                                proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
                            }
                            return
                        }
                        followsNewest = new.isNearBottom
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

                    // Its own stack, so the fade animates only the button and
                    // never a scroll that happens in the same update.
                    ZStack {
                        if !followsNewest {
                            Button {
                                withAnimation(reduceMotion ? nil : AppTheme.Motion.slow) {
                                    proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
                                }
                            } label: {
                                Label("Jump to latest", systemImage: "arrow.down")
                                    .labelStyle(.iconOnly)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            // Half its size: a circle.
                            .elevatedSurface(radius: 16)
                            .padding(AppTheme.Spacing.large)
                            .help("Jump to latest")
                            .accessibilityLabel("Jump to latest message")
                            .transition(.opacity)
                        }
                    }
                    .animation(AppTheme.Motion.fast, value: followsNewest)
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
                dismissAttachmentUploadFailure: dismissAttachmentUploadFailure,
                draftChanged: draftChanged,
                typingChanged: typingChanged,
                send: sendDraft
            )
            .overlay(alignment: .topLeading) {
                if let typingDescription {
                    // Sits in the clear band between the faded timeline and the
                    // composer, in line with the composer's left edge.
                    TypingIndicator(text: typingDescription)
                        .alignmentGuide(.top) { $0[.bottom] - Self.typingIndicatorDrop }
                        .padding(.leading, AppTheme.Spacing.extraLarge + AppTheme.Spacing.small)
                        .transition(.opacity)
                }
            }
            .animation(AppTheme.Motion.base, value: typingDescription)
        }
        .background(AppTheme.Colors.canvas)
        .onReceive(Self.dayLabelRefreshes) { _ in
            labelsReferenceDate = .now
        }
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
                RoundedRectangle(cornerRadius: AppTheme.Radius.large, style: .continuous)
                    .strokeBorder(
                        AppTheme.Colors.accentOutline,
                        style: StrokeStyle(lineWidth: 2, dash: [8])
                    )
                    .background(
                        AppTheme.Colors.accentSoft,
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.large, style: .continuous)
                    )
                    .overlay {
                        Label("Drop to upload", systemImage: "arrow.up.doc")
                            .font(AppTheme.Typography.bodyStrong)
                            .padding(AppTheme.Spacing.large)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(AppTheme.Spacing.small)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(AppTheme.Motion.fast, value: isDropTargeted)
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
        .onChange(of: page.key) {
            pendingQuote = nil
        }
        .onChange(of: initialDraft) {
            // Persisted drafts can arrive after the surface appears.
            if draft.isEmpty, acceptsSavedDraft {
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
        acceptsSavedDraft = false
        // Forget the saved text now, not on the next change callback, so a
        // re-evaluation in between cannot read the sent message back as a draft.
        draftChanged?("")
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

/// Where the timeline is scrolled, for deciding whether it follows the newest message.
struct TimelineScrollMetrics: Equatable {
    var contentHeight: CGFloat
    var offset: CGFloat
    var containerHeight: CGFloat

    /// Within this distance of the end, the timeline keeps following new messages.
    static let followThreshold: CGFloat = 72

    var isNearBottom: Bool {
        contentHeight - offset - containerHeight < Self.followThreshold
    }
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
        renameChannel: (() -> Void)? = nil,
        showsDetails: Bool = true
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
                renameChannel: renameChannel,
                showsDetails: showsDetails
            )
        )
    }
}

/// Hides the timeline behind the toolbar and fades it in just below, and fades
/// it out above the composer, so messages never end in a hard edge. Nothing
/// fades at rest: the first message starts below the top band and the timeline
/// keeps `bottomLength` of empty space under the newest one.
///
/// The bands are long and follow an ease-in-out curve: short linear ramps (18
/// and 16 pt before) showed a visible line where the fade began.
private struct TimelineEdgeFade: View {
    let toolbarInset: CGFloat

    /// How far the top fade starts above the toolbar's lower edge.
    private static let leadIn: CGFloat = 8
    private static let topLength: CGFloat = 36
    static let bottomLength: CGFloat = 32

    /// Extra space above the first message, so that with its own top padding it
    /// starts below the top band.
    static var topClearance: CGFloat {
        max(topLength - leadIn - AppTheme.Metrics.blockTopInset, 0)
    }

    /// Opacity stops of a smoothstep curve, from clear to opaque.
    private static let easedStops: [Gradient.Stop] = (0...8).map { step in
        let t = Double(step) / 8
        return Gradient.Stop(color: .black.opacity(t * t * (3 - 2 * t)), location: t)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: max(toolbarInset - Self.leadIn, 0))
            LinearGradient(
                stops: Self.easedStops,
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.topLength)
            Color.black
            LinearGradient(
                stops: Self.easedStops,
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: Self.bottomLength)
        }
        .ignoresSafeArea(.container, edges: .vertical)
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
    let showsDetails: Bool

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
                            .font(AppTheme.Typography.title)
                            .foregroundStyle(AppTheme.Colors.primaryText)

                        if let status {
                            Text(status)
                                .font(AppTheme.Typography.caption)
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
                            .font(AppTheme.Typography.caption)
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

                    if showsDetails {
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
}

extension ConversationSurface {
    /// The moments after which "Today" and "Yesterday" may name other days.
    /// Built once and shared, so redrawing the surface does not resubscribe.
    @MainActor private static let dayLabelRefreshes: AnyPublisher<Void, Never> = {
        let center = NotificationCenter.default
        return Publishers.MergeMany(
            center.publisher(for: .NSCalendarDayChanged),
            center.publisher(for: .NSSystemTimeZoneDidChange),
            center.publisher(for: NSApplication.didBecomeActiveNotification),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
        )
        .map { _ in () }
        .receive(on: RunLoop.main)
        .eraseToAnyPublisher()
    }()
}

/// A centered date between two hairlines above the first message of each day.
private struct DateSeparator: View {
    let date: Date
    /// The moment "Today" means; passed in so the label redraws when it changes.
    let now: Date

    var body: some View {
        HStack(spacing: AppTheme.Spacing.medium) {
            hairline
            Text(label)
                .font(AppTheme.Typography.captionStrong)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .fixedSize()
            hairline
        }
        .padding(.horizontal, AppTheme.Spacing.medium)
        .padding(.top, AppTheme.Spacing.large)
        .padding(.bottom, AppTheme.Spacing.extraSmall)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var label: String {
        MessageTimestamp.dayLabel(for: date, now: now)
    }

    private var hairline: some View {
        Rectangle()
            .fill(AppTheme.Colors.stroke)
            .frame(height: AppTheme.Metrics.hairline)
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
    let cancelSend: () -> Void
    let cancelAction: () -> Void
    let mediaLocalURLs: [String: String]
    let mediaFailures: [String: String]
    let requestMedia: ((String) -> Void)?
    let retryMedia: ((String) -> Void)?
    var readers: [ReadReceiptReader] = []
    var senderStatus: UserStatusDisplay?
    var sourceLabel: String?

    private var density: MessageDensity {
        MessageDensityPreference.shared.density
    }

    @State private var isHovered = false
    @State private var isHoveringActions = false
    @State private var isPickingReaction = false

    /// The pointer is over the message or its action bar, which floats above the
    /// row's top edge and so partly outside the row's own hover area.
    private var isActive: Bool {
        isHovered || isHoveringActions
    }

    var body: some View {
        // Element-style: the first message of a block opens with the avatar and the
        // sender's name beside it; every message's own lines sit below, with its
        // time in the avatar column while the pointer is over it.
        VStack(alignment: .leading, spacing: AppTheme.Spacing.extraSmall) {
            if !isContinuation {
                HStack(alignment: .center, spacing: AppTheme.Spacing.medium) {
                    AvatarImage(
                        initials: message.senderInitials,
                        remoteURL: message.senderAvatarURL,
                        size: Self.avatarSize,
                        mediaLocalURLs: mediaLocalURLs,
                        requestMedia: requestMedia
                    )
                    Text(message.senderName)
                        .font(AppTheme.Typography.calloutStrong)
                        .foregroundStyle(SenderColor.color(for: message.senderID))
                        .lineLimit(1)
                    UserStatusEmoji(status: senderStatus, size: 13)
                    // The first message of a block always shows its time; the
                    // messages that continue it show theirs on hover.
                    Text(message.timestamp, format: MessageTimestamp.clockStyle())
                        .font(AppTheme.Typography.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                        .lineLimit(1)
                        .fixedSize()
                        .help(message.timestamp.formatted(date: .complete, time: .standard))
                    if let sourceLabel {
                        // Like the time beside the message, it appears on hover.
                        Text(sourceLabel)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Colors.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // The sender's name keeps its room first.
                            .layoutPriority(-1)
                            .opacity(isActive ? 1 : 0)
                            .help(sourceLabel)
                            .accessibilityLabel("In \(sourceLabel)")
                    }
                    otherPendingLabel
                    Spacer(minLength: 0)
                }
            }

            HStack(alignment: .top, spacing: AppTheme.Spacing.medium) {
                Text(message.timestamp, format: MessageTimestamp.clockStyle())
                    .font(AppTheme.Typography.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.Colors.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: Self.avatarSize, alignment: .center)
                    .padding(.top, 2)
                    // The first message's time sits beside the sender's name.
                    .opacity(isActive && isContinuation ? 1 : 0)
                    .help(message.timestamp.formatted(date: .complete, time: .standard))
                    .accessibilityHidden(true)

                messageBody

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.medium)
        .padding(
            .top,
            isContinuation
                ? density.continuationInset
                : density.blockTopInset
        )
        .padding(
            .bottom,
            isContinuation
                ? density.continuationInset
                : density.blockBottomInset
        )
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.medium,
                style: .continuous
            )
            .fill(
                isFocusedSearchResult
                    ? AppTheme.Colors.accentSoft
                    : isActive
                        ? AppTheme.Colors.fillHover.opacity(0.8)
                        : .clear
            )
        }
        .overlay {
            if isFocusedSearchResult {
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.medium,
                    style: .continuous
                )
                .strokeBorder(AppTheme.Colors.accentOutline, lineWidth: AppTheme.Metrics.hairline)
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
            .onHover { isHoveringActions = $0 }
            // Straddles the top edge, above the row's right corner, so it never
            // covers the read receipts at the bottom of a one-line message.
            .alignmentGuide(.top) { $0[.bottom] - Self.actionBarOverlap }
            .padding(.trailing, AppTheme.Spacing.small)
            .opacity(isActive || isPickingReaction ? 1 : 0)
            // While hidden it must not catch the pointer over the row above.
            .allowsHitTesting(isActive || isPickingReaction)
            .accessibilityHidden(!isActive && !isPickingReaction)
        }
        // Only opacities and fills depend on `isActive`, so this fades the
        // hover affordances without animating the row's layout.
        .animation(AppTheme.Motion.fast, value: isActive)
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

    private static let avatarSize: CGFloat = 30
    /// How far the floating action bar reaches down into its own row.
    private static let actionBarOverlap: CGFloat = 10

    /// The message's own lines: content with its status note, reactions and read receipts.
    private var messageBody: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.extraSmall) {
            if isContinuation, hasOtherPendingAction {
                HStack(spacing: AppTheme.Spacing.small) {
                    otherPendingLabel
                }
            }

            // The whole message is shown from the start, even while it is being
            // sent or edited; the status follows it as small gray text.
            MessageContentView(
                blocks: message.content,
                mediaLocalURLs: mediaLocalURLs,
                mediaFailures: mediaFailures,
                requestMedia: requestMedia,
                retryMedia: retryMedia,
                trailingNote: statusContinuesText ? trailingStatus : nil
            )

            // Content that does not end in a paragraph (a picture, code, a list)
            // has no line to continue, so the note gets a line of its own.
            if let trailingStatus, !statusContinuesText {
                Text(trailingStatus)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.tertiaryText)
                    .help(trailingStatusHelp ?? "")
            }

            if !message.reactions.isEmpty {
                ReactionChips(
                    reactions: message.reactions,
                    isDisabled: message.actionState.isPending || message.deliveryState != .sent,
                    react: react
                )
            }

            if message.deliveryState == .failed {
                failureRow(
                    text: "Not sent",
                    retryHelp: "Retry send",
                    cancelHelp: "Cancel send",
                    retry: retrySend,
                    cancel: cancelSend
                )
            } else if case let .failed(_, failure) = message.actionState {
                failureRow(
                    text: failure,
                    retryHelp: "Retry",
                    cancelHelp: "Cancel",
                    retry: retryAction,
                    cancel: cancelAction
                )
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
        .animation(AppTheme.Motion.base, value: readers)
    }

    /// Why the message failed, with retry and cancel icons at the right.
    private func failureRow(
        text: String,
        retryHelp: String,
        cancelHelp: String,
        retry: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.small) {
            Text(text)
                .lineLimit(1)
                .foregroundStyle(AppTheme.Colors.destructive)
            Spacer(minLength: 0)
            Button(action: retry) {
                Image(systemName: "arrow.clockwise")
            }
            .help(retryHelp)
            .accessibilityLabel(retryHelp)
            Button(action: cancel) {
                Image(systemName: "xmark")
            }
            .help(cancelHelp)
            .accessibilityLabel(cancelHelp)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(AppTheme.Colors.secondaryText)
        .font(AppTheme.Typography.caption)
    }

    /// The small gray note after the message: "Sending…" until the server has it,
    /// "Editing…" until it accepts an edit, otherwise "(edited)".
    private var trailingStatus: String? {
        if message.deliveryState == .pending {
            return "Sending…"
        }
        if case .pending(.edit) = message.actionState {
            return "Editing…"
        }
        return message.editedAt == nil ? nil : "(edited)"
    }

    private var trailingStatusHelp: String? {
        guard trailingStatus == "(edited)", let editedAt = message.editedAt else {
            return nil
        }
        return "Edited \(editedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// The note follows the last paragraph of the message on the same line.
    private var statusContinuesText: Bool {
        trailingStatus != nil && MessageContentView.canInlineTrailingNote(message.content)
    }

    /// An action other than an edit still in flight (delete, reaction, star, read state).
    private var hasOtherPendingAction: Bool {
        if case let .pending(kind) = message.actionState {
            return kind != .edit
        }
        return false
    }

    @ViewBuilder
    private var otherPendingLabel: some View {
        if case let .pending(kind) = message.actionState, kind != .edit {
            Text(pendingLabel(kind))
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText)
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
        .padding(AppTheme.Spacing.extraExtraSmall)
        .elevatedSurface(radius: AppTheme.Radius.medium)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 30, height: AppTheme.ControlHeight.regular)
        }
        .buttonStyle(HoverFillButtonStyle())
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
                .font(AppTheme.Typography.caption)
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
                                .font(AppTheme.Typography.caption)
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
                .background(AppTheme.Colors.surfaceSunken)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppTheme.Radius.medium,
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
    let dismissAttachmentUploadFailure: (() -> Void)?
    let draftChanged: ((String) -> Void)?
    let typingChanged: ((Bool) -> Void)?
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
                    .padding(.vertical, AppTheme.Spacing.extraSmall)
                    .background(index == highlighted ? AppTheme.Colors.accentSoft : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(AppTheme.Colors.surfaceSunken)
        // Nested in the composer: its radius less the composer's padding.
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.small,
                style: .continuous
            )
        )
        .accessibilityLabel("Mention suggestions")
    }

    private var placeholder: String {
        hint.map { "Message \(conversationTitle) · \($0)" } ?? "Message \(conversationTitle)"
    }

    /// Looks for the first visible character instead of trimming a copy of the
    /// whole draft, which cost a full copy of a long paste on every keystroke.
    private var canSend: Bool {
        quote != nil || draft.contains { !$0.isWhitespace }
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
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText)
            case let .failed(filename, message):
                HStack(spacing: AppTheme.Spacing.small) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("\(filename): \(message)")
                        .lineLimit(2)
                        .help("\(filename): \(message)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let retryAttachmentUpload {
                        Button("Retry", action: retryAttachmentUpload)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .fixedSize()
                    }
                    if let dismissAttachmentUploadFailure {
                        Button(action: dismissAttachmentUploadFailure) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss upload error")
                    }
                }
                .font(AppTheme.Typography.caption)
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
                .font(AppTheme.Typography.caption)
                .padding(.vertical, AppTheme.Spacing.small)
                .padding(.horizontal, AppTheme.Spacing.medium)
                .background(AppTheme.Colors.surfaceSunken)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppTheme.Radius.small,
                        style: .continuous
                    )
                )
            }

            if let match = mentionMatch {
                mentionList(match)
            }

            // One row: attach, the text (growing upward to six lines) and send.
            HStack(alignment: .bottom, spacing: AppTheme.Spacing.small) {
                Button {
                    chooseAttachment?()
                } label: {
                    Image(systemName: "plus")
                        .font(AppTheme.Typography.scaled(13, weight: .medium))
                }
                .buttonStyle(CircleHoverButtonStyle())
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .disabled(
                    isDisabled
                        || chooseAttachment == nil
                        || attachmentUploadState.isUploading
                )
                .help("Add attachment")
                .accessibilityLabel("Add attachment")

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
                    // Kept here rather than on the surface, so typing does not
                    // re-evaluate the whole timeline beside the composer.
                    draftChanged?(draft)
                    // Text restored from a saved draft is not typing; only the
                    // focused composer announces it, and emptying the box always
                    // withdraws it.
                    if draft.isEmpty || isFocused.wrappedValue {
                        typingChanged?(!draft.isEmpty)
                    }
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
                // As tall as the buttons, so a single line sits centered beside them.
                .frame(minHeight: ComposerMetrics.buttonSize)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(AppTheme.Typography.scaled(12, weight: .semibold))
                        .frame(width: ComposerMetrics.buttonSize, height: ComposerMetrics.buttonSize)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                // A faded accent while there is nothing to send, not a gray button.
                .background(AppTheme.Colors.accent.opacity(canSend ? 1 : 0.4))
                .clipShape(Circle())
                .animation(AppTheme.Motion.fast, value: canSend)
                .disabled(!canSend)
                .help("Send message")
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.medium)
        .padding(.vertical, ComposerMetrics.verticalPadding)
        .frame(maxWidth: AppTheme.Metrics.composerMaximumWidth)
        .elevatedSurface(radius: AppTheme.Radius.large)
        .padding(.horizontal, AppTheme.Spacing.extraLarge)
        .padding(.vertical, AppTheme.Spacing.medium)
        .opacity(isDisabled ? AppTheme.Colors.disabledOpacity : 1)
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

/// The composer card's size: a one-line composer is the button height plus
/// the vertical padding twice (42 pt).
private enum ComposerMetrics {
    static let buttonSize: CGFloat = 26
    static let verticalPadding: CGFloat = 8
}

/// A round hit area, as large as the send button, that lights up under the
/// pointer, for the composer's icon buttons.
private struct CircleHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CircleHoverButton(configuration: configuration)
    }

    private struct CircleHoverButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        private var fill: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return AppTheme.Colors.fillPressed }
            return isHovered ? AppTheme.Colors.fillHover : .clear
        }

        var body: some View {
            configuration.label
                .frame(width: ComposerMetrics.buttonSize, height: ComposerMetrics.buttonSize)
                .background(Circle().fill(fill))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : AppTheme.Colors.disabledOpacity)
                .onHover { isHovered = $0 }
                .animation(AppTheme.Motion.fast, value: isHovered)
                .animation(AppTheme.Motion.instant, value: configuration.isPressed)
        }
    }
}

/// A small note floating above the composer while someone else is typing.
private struct TypingIndicator: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTheme.Typography.caption)
            .foregroundStyle(AppTheme.Colors.secondaryText)
            .lineLimit(1)
            .allowsHitTesting(false)
            .accessibilityLabel(text)
    }
}
