import SwiftUI
import ZulipCoreBindings

enum SidebarSessionAction: Equatable {
    case connect
    case disconnect

    var title: String {
        switch self {
        case .connect:
            "Connect to Zulip…"
        case .disconnect:
            "Disconnect"
        }
    }

    var systemImage: String {
        switch self {
        case .connect:
            "bolt.horizontal.circle"
        case .disconnect:
            "rectangle.portrait.and.arrow.right"
        }
    }

    var role: ButtonRole? {
        self == .disconnect ? .destructive : nil
    }
}

struct SidebarSessionControl {
    let action: SidebarSessionAction
    let perform: () -> Void
}

struct SidebarView: View {
    let model: SidebarViewModel
    @Binding var selection: ConversationKey
    let openCommandPalette: () -> Void
    var startNewTopic: (ChannelSnapshot) -> Void = { _ in }
    var createChannel: (() -> Void)?
    var renameChannel: ((ChannelSnapshot) -> Void)?
    /// Turns notifications for every message of a channel on or off.
    var setChannelNotifications: ((ChannelSnapshot, Bool) -> Void)?
    /// Sets one topic to Followed, Default or Muted (or Unmuted, inside a
    /// muted channel).
    var setTopicNotification: ((ChannelSnapshot, TopicSnapshot, TopicNotificationLevel) -> Void)?
    /// The account-wide default for channels without a setting of their own,
    /// and the way to change it.
    var notifiesForAllChannels = false
    var setNotifiesForAllChannels: ((Bool) -> Void)?
    var presenceDescription: ((Int64) -> String?)?
    /// Someone's status, shown as an emoji after their name.
    var userStatus: ((Int64) -> UserStatusDisplay?)?
    /// The user's own status and invisible mode, behind their avatar.
    var profileStatus: ProfileStatusControl?
    var sessionControl: SidebarSessionControl?
    var mediaLocalURLs: [String: String] = [:]
    var requestMedia: ((String) -> Void)?
    @Environment(UpdateController.self) private var updates: UpdateController?
    @State private var isProfilePopoverShown = false
    /// The channel row under the pointer; its chevron and "+" show only then
    /// (or while it is selected or expanded).
    @State private var hoveredChannelID: Int64?

    /// Zulip's three levels for a topic. Inside a muted channel a topic is
    /// either left muted with its channel or unmuted.
    @ViewBuilder
    private func topicNotificationMenu(
        channel: ChannelSnapshot,
        topic: TopicSnapshot,
        set: @escaping (ChannelSnapshot, TopicSnapshot, TopicNotificationLevel) -> Void
    ) -> some View {
        Button(topic.notification == .followed ? "✓ Follow Topic" : "Follow Topic") {
            set(channel, topic, .followed)
        }
        Button(
            topic.notification == .standard
                ? "✓ Default" : "Default"
        ) {
            set(channel, topic, .standard)
        }
        if channel.isMuted {
            Button(topic.notification == .unmuted ? "✓ Unmute Topic" : "Unmute Topic") {
                set(channel, topic, .unmuted)
            }
        }
        Button(topic.notification == .muted ? "✓ Mute Topic" : "Mute Topic") {
            set(channel, topic, .muted)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
                .padding(.horizontal, AppTheme.Spacing.medium)
                .padding(.top, AppTheme.Metrics.sidebarTopInset)
                .padding(.bottom, AppTheme.Spacing.small)

            Button(action: openCommandPalette) {
                HStack(spacing: AppTheme.Spacing.small) {
                    Image(systemName: "magnifyingglass")
                    Text("Search or jump")
                    Spacer()
                    Text("⌘K")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                }
                .font(AppTheme.Typography.callout)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .padding(.horizontal, AppTheme.Spacing.small)
                .frame(minHeight: AppTheme.ControlHeight.row)
                .background(AppTheme.Colors.fillHover)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppTheme.Radius.medium,
                        style: .continuous
                    )
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, AppTheme.Spacing.medium)
            .padding(.bottom, AppTheme.Spacing.small)
            .accessibilityLabel("Search or jump to a conversation")

            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.extraSmall) {
                    ForEach(model.snapshot.quickLinks) { item in
                        SidebarRow(
                            title: item.title,
                            systemImage: item.systemImage,
                            unreadCount: item.unreadCount,
                            isSelected: selection == item.key
                        ) {
                            selection = item.key
                        }
                    }

                    SidebarSectionHeader(
                        title: "Channels",
                        count: model.snapshot.channels.count,
                        isExpanded: model.areChannelsExpanded,
                        action: model.toggleChannels,
                        addTitle: createChannel == nil ? nil : "New channel",
                        add: createChannel
                    )
                    .padding(.top, AppTheme.Spacing.medium)

                    if model.areChannelsExpanded {
                        ForEach(model.snapshot.channels) { channel in
                            let key = model.key(for: channel)
                            let isExpanded = model.isChannelExpanded(channel.streamID)
                            let showsAccessories = hoveredChannelID == channel.streamID
                                || selection == key
                            HStack(spacing: 0) {
                                Button {
                                    model.toggleChannel(channel.streamID)
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .font(AppTheme.Typography.scaled(9, weight: .semibold))
                                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                        .motion(AppTheme.Motion.base, value: isExpanded)
                                        .frame(
                                            width: AppTheme.Metrics.topicIndent,
                                            height: AppTheme.ControlHeight.row
                                        )
                                }
                                .buttonStyle(HoverFillButtonStyle())
                                .foregroundStyle(AppTheme.Colors.tertiaryText)
                                // An expanded channel keeps its chevron as a state mark.
                                .opacity(showsAccessories || isExpanded ? 1 : 0)
                                .help(
                                    model.isChannelExpanded(channel.streamID)
                                        ? "Collapse topics"
                                        : "Expand topics"
                                )
                                .accessibilityLabel(
                                    "\(model.isChannelExpanded(channel.streamID) ? "Collapse" : "Expand") \(channel.name) topics"
                                )

                                SidebarRow(
                                    title: channel.name,
                                    unreadCount: channel.unreadCount,
                                    isSelected: selection == key,
                                    isMuted: channel.isMuted,
                                    leading: {
                                        Circle()
                                            .fill(ChannelColor.color(hex: channel.colorHex))
                                            .frame(width: 8, height: 8)
                                    }
                                ) {
                                    selection = key
                                }
                                .contextMenu {
                                    Button("New topic…") {
                                        startNewTopic(channel)
                                    }
                                    if let setChannelNotifications {
                                        Button(
                                            channel.notifiesForAllMessages
                                                ? "Turn Off Notifications"
                                                : "Turn On Notifications"
                                        ) {
                                            setChannelNotifications(
                                                channel,
                                                !channel.notifiesForAllMessages
                                            )
                                        }
                                    }
                                    if let renameChannel {
                                        Button("Rename channel…") {
                                            renameChannel(channel)
                                        }
                                    }
                                }

                                Button {
                                    startNewTopic(channel)
                                } label: {
                                    Image(systemName: "plus")
                                        .font(AppTheme.Typography.scaled(10, weight: .semibold))
                                        .frame(width: 24, height: AppTheme.ControlHeight.row)
                                }
                                .buttonStyle(HoverFillButtonStyle())
                                .foregroundStyle(AppTheme.Colors.tertiaryText)
                                .opacity(showsAccessories ? 1 : 0)
                                .help("Start a new topic in \(channel.name)")
                                .accessibilityLabel("New topic in \(channel.name)")
                            }
                            .onHover { isHovering in
                                if isHovering {
                                    hoveredChannelID = channel.streamID
                                } else if hoveredChannelID == channel.streamID {
                                    hoveredChannelID = nil
                                }
                            }
                            .animation(AppTheme.Motion.fast, value: showsAccessories)

                            if model.isChannelExpanded(channel.streamID) {
                                ForEach(channel.topics) { topic in
                                    let topicKey = model.key(for: topic)
                                    SidebarRow(
                                        title: TopicName.display(topic.name),
                                        systemImage: "text.bubble",
                                        unreadCount: topic.unreadCount,
                                        isSelected: selection == topicKey,
                                        isMuted: topic.notification == .muted
                                            || (channel.isMuted && topic.notification != .unmuted
                                                && topic.notification != .followed),
                                        isFollowed: topic.notification == .followed
                                    ) {
                                        selection = topicKey
                                    }
                                    .contextMenu {
                                        if let setTopicNotification {
                                            topicNotificationMenu(
                                                channel: channel,
                                                topic: topic,
                                                set: setTopicNotification
                                            )
                                        }
                                    }
                                    .padding(.leading, AppTheme.Metrics.topicIndent)
                                }
                            }
                        }
                    }

                    SidebarSectionHeader(
                        title: "Direct messages",
                        count: model.snapshot.directMessages.count,
                        isExpanded: model.areDirectMessagesExpanded,
                        action: model.toggleDirectMessages
                    )
                    .padding(.top, AppTheme.Spacing.medium)

                    if model.areDirectMessagesExpanded {
                        ForEach(model.snapshot.directMessages) { directMessage in
                            let key = model.key(for: directMessage)
                            let status = userStatus?(directMessage.userID)
                            SidebarRow(
                                title: directMessage.displayName,
                                unreadCount: directMessage.unreadCount,
                                isSelected: selection == key,
                                status: status,
                                leading: {
                                    AvatarView(
                                        initials: directMessage.initials,
                                        presence: directMessage.presence,
                                        avatarURL: directMessage.avatarURL,
                                        mediaLocalURLs: mediaLocalURLs,
                                        requestMedia: requestMedia
                                    )
                                }
                            ) {
                                selection = key
                            }
                            .help(
                                [
                                    status.flatMap { $0.text.isEmpty ? nil : $0.text },
                                    presenceDescription?(directMessage.userID),
                                ]
                                .compactMap { $0 }
                                .joined(separator: " · ")
                            )
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.small)
                .padding(.bottom, AppTheme.Spacing.large)
            }

            profileRow
                .padding(AppTheme.Spacing.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace navigation")
    }

    private var workspaceHeader: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            AvatarImage(
                initials: String(model.snapshot.organizationName.prefix(1)),
                remoteURL: model.snapshot.organizationIconURL,
                size: 30,
                cornerRadius: 8,
                fallbackFill: AppTheme.Colors.accent,
                fallbackForeground: .white,
                mediaLocalURLs: mediaLocalURLs,
                requestMedia: requestMedia
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(model.snapshot.organizationName)
                    .font(AppTheme.Typography.calloutMedium)
                    .foregroundStyle(AppTheme.Colors.primaryText)
                    .lineLimit(1)
                Text(model.snapshot.organizationHost)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 36)
    }

    private func ownAvatar(size: CGFloat) -> some View {
        AvatarImage(
            initials: model.snapshot.currentUserInitials,
            remoteURL: model.snapshot.currentUserAvatarURL,
            size: size,
            mediaLocalURLs: mediaLocalURLs,
            requestMedia: requestMedia
        )
    }

    private var profileIdentity: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            ownAvatar(size: 24)

            Text(model.snapshot.currentUserName)
                .font(AppTheme.Typography.callout)
                .lineLimit(1)

            if let profileStatus {
                UserStatusEmoji(status: profileStatus.status, size: 12)
                if profileStatus.isInvisible {
                    Image(systemName: "eye.slash")
                        .font(AppTheme.Typography.scaled(10))
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                        .help("Invisible mode is on")
                }
            }
        }
    }

    private var profileRow: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            if let profileStatus {
                Button {
                    isProfilePopoverShown.toggle()
                } label: {
                    profileIdentity
                        .padding(.vertical, 2)
                        .padding(.trailing, AppTheme.Spacing.small)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Set your status")
                .accessibilityLabel("Profile, \(model.snapshot.currentUserName)")
                .accessibilityHint("Shows your status and invisible mode")
                .popover(isPresented: $isProfilePopoverShown, arrowEdge: .top) {
                    ProfileStatusPopover(
                        name: model.snapshot.currentUserName,
                        avatar: AnyView(ownAvatar(size: 40)),
                        control: profileStatus,
                        close: { isProfilePopoverShown = false }
                    )
                }
            } else {
                profileIdentity
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Profile, \(model.snapshot.currentUserName)")
            }

            Spacer()

            Menu {
                if let sessionControl {
                    Button(role: sessionControl.action.role) {
                        sessionControl.perform()
                    } label: {
                        Label(
                            sessionControl.action.title,
                            systemImage: sessionControl.action.systemImage
                        )
                    }

                    Divider()
                }

                if let setNotifiesForAllChannels {
                    Toggle(
                        "Notify for All Channel Messages",
                        isOn: Binding(
                            get: { notifiesForAllChannels },
                            set: setNotifiesForAllChannels
                        )
                    )

                    Divider()
                }

                if let release = updates?.availableRelease {
                    SettingsLink {
                        Label("Update to \(release.version)…", systemImage: "arrow.down.circle")
                    }
                }

                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(AppTheme.Typography.scaled(12))
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Profile and settings")
            .accessibilityLabel("Profile and settings for \(model.snapshot.currentUserName)")
        }
        .padding(.horizontal, AppTheme.Spacing.small)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let action: () -> Void
    var addTitle: String?
    var add: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            toggleButton
            if let add, let addTitle {
                Button(action: add) {
                    Image(systemName: "plus")
                        .font(AppTheme.Typography.scaled(11, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                        .frame(width: 26, height: AppTheme.ControlHeight.regular)
                }
                .buttonStyle(HoverFillButtonStyle())
                .help(addTitle)
                .accessibilityLabel(addTitle)
            }
        }
    }

    private var toggleButton: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.extraSmall) {
                Image(systemName: "chevron.right")
                    .font(AppTheme.Typography.scaled(9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .motion(AppTheme.Motion.base, value: isExpanded)
                    .frame(width: 10)
                    .foregroundStyle(AppTheme.Colors.tertiaryText)

                Text(title)
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Colors.secondaryText)

                Spacer()

                Text("\(count)")
                    .font(AppTheme.Typography.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.Colors.tertiaryText)
            }
            .padding(.horizontal, AppTheme.Spacing.small)
            .frame(minHeight: AppTheme.ControlHeight.regular)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

private struct SidebarRow<Leading: View>: View {
    let title: String
    var systemImage: String?
    var unreadCount = 0
    let isSelected: Bool
    var isMuted = false
    var isFollowed = false
    var status: UserStatusDisplay?
    @ViewBuilder var leading: () -> Leading
    let action: () -> Void

    @State private var isHovered = false

    init(
        title: String,
        systemImage: String? = nil,
        unreadCount: Int = 0,
        isSelected: Bool,
        isMuted: Bool = false,
        isFollowed: Bool = false,
        status: UserStatusDisplay? = nil,
        @ViewBuilder leading: @escaping () -> Leading,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.unreadCount = unreadCount
        self.isSelected = isSelected
        self.isMuted = isMuted
        self.isFollowed = isFollowed
        self.status = status
        self.leading = leading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.small) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(AppTheme.Typography.scaled(12, weight: .medium))
                        .frame(width: 16)
                } else {
                    leading()
                        .frame(width: 16)
                }

                Text(title)
                    .font(
                        unreadCount > 0
                            ? AppTheme.Typography.calloutStrong
                            : AppTheme.Typography.callout
                    )
                    .lineLimit(1)

                UserStatusEmoji(status: status, size: 11)

                Spacer(minLength: AppTheme.Spacing.extraSmall)

                if isFollowed {
                    Image(systemName: "bell.fill")
                        .font(AppTheme.Typography.scaled(9, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                        .accessibilityLabel("Followed")
                }

                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(AppTheme.Typography.captionStrong.monospacedDigit())
                        .foregroundStyle(
                            isSelected
                                ? AppTheme.Colors.primaryText
                                : AppTheme.Colors.secondaryText
                        )
                        .padding(.horizontal, AppTheme.Spacing.extraSmall + 1)
                        .frame(minWidth: 20, minHeight: 18)
                        // Darker than the hover fill, so a badge never looks hovered.
                        .background(AppTheme.Colors.fillPressed)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(
                isMuted
                    ? AppTheme.Colors.tertiaryText
                    : AppTheme.Colors.primaryText
            )
            .padding(.horizontal, AppTheme.Spacing.small)
            .frame(minHeight: AppTheme.ControlHeight.row)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.medium,
                    style: .continuous
                )
                .fill(
                    isSelected
                        ? AppTheme.Colors.accentSoft
                        : isHovered
                            ? AppTheme.Colors.fillHover
                            : .clear
                )
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(AppTheme.Motion.fast, value: isHovered)
        .animation(AppTheme.Motion.fast, value: isSelected)
        .accessibilityLabel(title)
        .accessibilityValue(unreadCount > 0 ? "\(unreadCount) unread" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension SidebarRow where Leading == EmptyView {
    init(
        title: String,
        systemImage: String,
        unreadCount: Int = 0,
        isSelected: Bool,
        isMuted: Bool = false,
        isFollowed: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            unreadCount: unreadCount,
            isSelected: isSelected,
            isMuted: isMuted,
            isFollowed: isFollowed,
            leading: { EmptyView() },
            action: action
        )
    }
}

private struct AvatarView: View {
    let initials: String
    let presence: PresenceState
    var avatarURL: String?
    var mediaLocalURLs: [String: String] = [:]
    var requestMedia: ((String) -> Void)?

    var body: some View {
        AvatarImage(
            initials: initials,
            remoteURL: avatarURL,
            size: 18,
            mediaLocalURLs: mediaLocalURLs,
            requestMedia: requestMedia
        )
            .overlay(alignment: .bottomTrailing) {
                presenceDot
                    .offset(x: 2, y: 2)
            }
    }

    /// A vivid filled dot when the person is around, a hollow ring when not, so
    /// the state shows by shape as well as by colour. It sits on a ring of the
    /// sidebar's background that separates it from the avatar.
    private var presenceDot: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
            switch presence {
            case .active:
                Circle()
                    .fill(AppTheme.Colors.presenceActive)
                    .padding(Self.ringWidth)
            case .idle:
                Circle()
                    .fill(AppTheme.Colors.presenceIdle)
                    .padding(Self.ringWidth)
            case .offline:
                Circle()
                    .strokeBorder(AppTheme.Colors.tertiaryText, lineWidth: 1.5)
                    .padding(Self.ringWidth)
            }
        }
        .frame(width: 10, height: 10)
    }

    private static let ringWidth: CGFloat = 1.5
}

#Preview("Sidebar") {
    @Previewable @State var selection = FixtureSidebar.defaultSelection

    SidebarView(
        model: SidebarViewModel(snapshot: FixtureSidebar.snapshot),
        selection: $selection,
        openCommandPalette: {}
    )
    .frame(width: AppTheme.Metrics.sidebarIdeal, height: 720)
}
