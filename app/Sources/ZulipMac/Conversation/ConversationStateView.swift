import SwiftUI
import ZulipCoreBindings

struct ConversationStateContainer: View {
    let key: ConversationKey
    @State private var state: ConversationLoadState

    init(key: ConversationKey) {
        self.key = key
        _state = State(initialValue: FixtureConversation.state(for: key))
    }

    var body: some View {
        ConversationStateView(
            state: state,
            retry: loadFixtureConversation
        )
    }

    private func loadFixtureConversation() {
        state = .loaded(
            FixtureConversation.page(
                for: key,
                messageCount: 1_000
            )
        )
    }
}

struct ConversationStateView: View {
    let state: ConversationLoadState
    let retry: () -> Void

    var body: some View {
        switch state {
        case let .loaded(page):
            ConversationSurface(page: page)

        case let .offline(page):
            ConversationSurface(
                page: page,
                isOffline: true,
                reconnect: retry
            )

        case let .loading(title, subtitle):
            ConversationPlaceholderShell(title: title, subtitle: subtitle) {
                TimelineLoadingView()
            }
            .accessibilityLabel("Loading \(title)")

        case let .empty(title, subtitle, message):
            ConversationPlaceholderShell(title: title, subtitle: subtitle) {
                ContentUnavailableView(
                    title,
                    systemImage: "text.bubble",
                    description: Text(message)
                )
            }

        case let .failure(title, subtitle, message):
            ConversationPlaceholderShell(title: title, subtitle: subtitle) {
                ContentUnavailableView {
                    Label("Couldn’t load \(title)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again", action: retry)
                }
            }
        }
    }
}

private struct ConversationPlaceholderShell<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ConversationPathHeader(
                title: title,
                subtitle: subtitle,
                isOffline: false
            )
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppTheme.Colors.canvas)
    }
}

private struct TimelineLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.extraLarge) {
            ForEach(0..<7, id: \.self) { index in
                HStack(alignment: .top, spacing: AppTheme.Spacing.medium) {
                    Circle()
                        .fill(AppTheme.Colors.hover)
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(AppTheme.Colors.hover)
                            .frame(width: 120, height: 11)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(AppTheme.Colors.hover)
                            .frame(
                                maxWidth: index.isMultiple(of: 2) ? 520 : 390,
                                minHeight: 12
                            )
                    }
                }
            }
        }
        .frame(maxWidth: AppTheme.Metrics.messageMaximumWidth)
        .padding(AppTheme.Spacing.extraLarge)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

#Preview("Conversation states") {
    VStack(spacing: 0) {
        ConversationStateView(
            state: .empty(
                title: "Starred",
                subtitle: "Northstar",
                message: "Star a message to keep it here."
            ),
            retry: {}
        )
    }
    .frame(width: 760, height: 560)
}
