import SwiftUI
import ZulipCoreBindings

struct SidebarView: View {
    let model: SidebarViewModel
    @Binding var selection: ConversationKey
    let openCommandPalette: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
                .padding(.horizontal, AppTheme.Spacing.medium)
                .padding(.top, 42)
                .padding(.bottom, AppTheme.Spacing.small)

            Button(action: openCommandPalette) {
                HStack(spacing: AppTheme.Spacing.small) {
                    Image(systemName: "magnifyingglass")
                    Text("Search or jump")
                    Spacer()
                    Text("⌘K")
                        .font(AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                }
                .font(AppTheme.Typography.sidebar)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .padding(.horizontal, AppTheme.Spacing.small)
                .frame(height: 32)
                .background(AppTheme.Colors.hover.opacity(0.65))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppTheme.Metrics.controlRadius,
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
                        action: model.toggleChannels
                    )
                    .padding(.top, AppTheme.Spacing.medium)

                    if model.areChannelsExpanded {
                        ForEach(model.snapshot.channels) { channel in
                            let key = model.key(for: channel)
                            SidebarRow(
                                title: channel.name,
                                unreadCount: channel.unreadCount,
                                isSelected: selection == key,
                                isMuted: channel.isMuted,
                                leading: {
                                    Circle()
                                        .fill(Color(hex: channel.colorHex))
                                        .frame(width: 8, height: 8)
                                }
                            ) {
                                selection = key
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
                            SidebarRow(
                                title: directMessage.displayName,
                                unreadCount: directMessage.unreadCount,
                                isSelected: selection == key,
                                leading: {
                                    AvatarView(
                                        initials: directMessage.initials,
                                        presence: directMessage.presence
                                    )
                                }
                            ) {
                                selection = key
                            }
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.small)
                .padding(.bottom, AppTheme.Spacing.large)
            }

            Divider()

            profileRow
                .padding(AppTheme.Spacing.small)
        }
        .background(AppTheme.Colors.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace navigation")
    }

    private var workspaceHeader: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.Colors.accent)
                .frame(width: 30, height: 30)
                .overlay {
                    Text(String(model.snapshot.organizationName.prefix(1)))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.canvas)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(model.snapshot.organizationName)
                    .font(AppTheme.Typography.sidebarEmphasized)
                    .foregroundStyle(AppTheme.Colors.primaryText)
                    .lineLimit(1)
                Text(model.snapshot.organizationHost)
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                // Account switching arrives with multi-account support.
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Workspace menu")
            .accessibilityLabel("Workspace menu")
        }
        .frame(height: 36)
    }

    private var profileRow: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            Text(model.snapshot.currentUserInitials)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(AppTheme.Colors.hover)
                .clipShape(Circle())

            Text(model.snapshot.currentUserName)
                .font(AppTheme.Typography.sidebar)
                .lineLimit(1)

            Spacer()

            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.Colors.secondaryText)
        }
        .padding(.horizontal, AppTheme.Spacing.small)
        .frame(height: 36)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Profile and settings, \(model.snapshot.currentUserName)")
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.extraSmall) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy(duration: 0.18), value: isExpanded)
                    .frame(width: 10)

                Text(title.uppercased())
                    .font(AppTheme.Typography.eyebrow)
                    .tracking(0.45)

                Spacer()

                Text("\(count)")
                    .font(AppTheme.Typography.metadata.monospacedDigit())
            }
            .foregroundStyle(AppTheme.Colors.tertiaryText)
            .padding(.horizontal, AppTheme.Spacing.small)
            .frame(height: 28)
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
    @ViewBuilder var leading: () -> Leading
    let action: () -> Void

    @State private var isHovered = false

    init(
        title: String,
        systemImage: String? = nil,
        unreadCount: Int = 0,
        isSelected: Bool,
        isMuted: Bool = false,
        @ViewBuilder leading: @escaping () -> Leading,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.unreadCount = unreadCount
        self.isSelected = isSelected
        self.isMuted = isMuted
        self.leading = leading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.small) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                } else {
                    leading()
                        .frame(width: 16)
                }

                Text(title)
                    .font(
                        unreadCount > 0
                            ? AppTheme.Typography.sidebarEmphasized
                            : AppTheme.Typography.sidebar
                    )
                    .lineLimit(1)

                Spacer(minLength: AppTheme.Spacing.extraSmall)

                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(
                            isSelected
                                ? AppTheme.Colors.primaryText
                                : AppTheme.Colors.secondaryText
                        )
                        .padding(.horizontal, 5)
                        .frame(minWidth: 20, minHeight: 18)
                        .background(AppTheme.Colors.hover)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(
                isMuted
                    ? AppTheme.Colors.tertiaryText
                    : AppTheme.Colors.primaryText
            )
            .padding(.horizontal, AppTheme.Spacing.small)
            .frame(height: 32)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(
                    cornerRadius: AppTheme.Metrics.controlRadius,
                    style: .continuous
                )
                .fill(
                    isSelected
                        ? AppTheme.Colors.selection
                        : isHovered
                            ? AppTheme.Colors.hover
                            : .clear
                )
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            unreadCount: unreadCount,
            isSelected: isSelected,
            leading: { EmptyView() },
            action: action
        )
    }
}

private struct AvatarView: View {
    let initials: String
    let presence: PresenceState

    var body: some View {
        Text(initials)
            .font(.system(size: 7.5, weight: .semibold))
            .frame(width: 18, height: 18)
            .background(AppTheme.Colors.hover)
            .clipShape(Circle())
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(presenceColor)
                    .frame(width: 6, height: 6)
                    .overlay {
                        Circle()
                            .stroke(AppTheme.Colors.sidebar, lineWidth: 1)
                    }
            }
    }

    private var presenceColor: Color {
        switch presence {
        case .active:
            AppTheme.Colors.success
        case .idle:
            AppTheme.Colors.warning
        case .offline:
            AppTheme.Colors.tertiaryText
        }
    }
}

private extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(sanitized, radix: 16) ?? 0x808080
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
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
