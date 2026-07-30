import SwiftUI
import ZulipCoreBindings

struct ConversationSurface: View {
    let page: ConversationPage
    var isOffline = false
    var reconnect: () -> Void = {}
    var submitMessage: ((String) -> Bool)?

    @State private var messages: [MessageViewData]
    @State private var draft = ""
    @State private var followsNewest = true
    @FocusState private var isComposerFocused: Bool

    init(
        page: ConversationPage,
        isOffline: Bool = false,
        reconnect: @escaping () -> Void = {},
        submitMessage: ((String) -> Bool)? = nil
    ) {
        self.page = page
        self.isOffline = isOffline
        self.reconnect = reconnect
        self.submitMessage = submitMessage
        _messages = State(initialValue: page.messages)
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationPathHeader(
                title: page.title,
                subtitle: page.subtitle,
                isOffline: isOffline
            )
            Divider()

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
                                Button("Load earlier messages") {
                                    // Pagination is wired to the core in MVP-001.
                                }
                                .buttonStyle(.borderless)
                                .font(AppTheme.Typography.metadata)
                                .foregroundStyle(AppTheme.Colors.secondaryText)
                                .padding(.vertical, AppTheme.Spacing.large)
                            }

                            ForEach(messages) { message in
                                MessageRow(
                                    message: message,
                                    toggleReaction: {
                                        toggleReaction(for: message.id)
                                    },
                                    toggleStar: {
                                        toggleStar(for: message.id)
                                    }
                                )
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
                    .task(id: page.key) {
                        proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
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

            Divider()

            ComposerView(
                conversationTitle: page.title,
                draft: $draft,
                isFocused: $isComposerFocused,
                isDisabled: isOffline,
                send: sendDraft
            )
        }
        .background(AppTheme.Colors.canvas)
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
                deliveryState: submitMessage == nil ? .sent : .pending
            )
        )
        draft = ""
        followsNewest = true
    }
}

private enum TimelineAnchor: Hashable {
    case bottom
}

struct ConversationPathHeader: View {
    let title: String
    let subtitle: String
    let isOffline: Bool

    var body: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            Text(subtitle)
                .foregroundStyle(AppTheme.Colors.secondaryText)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.tertiaryText)

            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(AppTheme.Colors.primaryText)

            Spacer()

            if isOffline {
                Label("Offline", systemImage: "wifi.slash")
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Colors.warning)
                    .padding(.horizontal, AppTheme.Spacing.small)
                    .frame(height: 24)
                    .background(AppTheme.Colors.warning.opacity(0.12))
                    .clipShape(Capsule())
            }

            Button {
                // Conversation details arrive with live membership data.
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.Colors.secondaryText)
            .help("Conversation details")
            .accessibilityLabel("Conversation details")
        }
        .font(AppTheme.Typography.body)
        .padding(.horizontal, AppTheme.Spacing.large)
        .frame(height: AppTheme.Metrics.headerHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(subtitle), \(title)\(isOffline ? ", offline" : "")"
        )
    }
}

private struct MessageRow: View {
    let message: MessageViewData
    let toggleReaction: () -> Void
    let toggleStar: () -> Void

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
                }

                MessageContentView(blocks: message.content)

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
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.medium)
        .padding(.vertical, AppTheme.Spacing.small)
        .contentShape(Rectangle())
        .background(isHovered ? AppTheme.Colors.hover.opacity(0.45) : .clear)
        .overlay(alignment: .topTrailing) {
            MessageActions(
                isStarred: message.isStarred,
                toggleReaction: toggleReaction,
                toggleStar: toggleStar
            )
            .padding(.top, 4)
            .padding(.trailing, AppTheme.Spacing.small)
            .opacity(isHovered ? 1 : 0)
            .accessibilityHidden(!isHovered)
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(message.senderName), \(message.plainText)")
        .accessibilityAction(named: "React") {
            toggleReaction()
        }
        .accessibilityAction(named: message.isStarred ? "Unstar" : "Star") {
            toggleStar()
        }
    }
}

private struct MessageActions: View {
    let isStarred: Bool
    let toggleReaction: () -> Void
    let toggleStar: () -> Void

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
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("More actions")
            .accessibilityLabel("More message actions")
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
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct ComposerView: View {
    let conversationTitle: String
    @Binding var draft: String
    var isFocused: FocusState<Bool>.Binding
    let isDisabled: Bool
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
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
                Button {} label: {
                    Image(systemName: "plus")
                }
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
