import SwiftUI

struct MessageSearchView: View {
    @Bindable var session: LiveSessionViewModel
    let openResult: (MessageSearchResult) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var highlightedID: MessageSearchResult.ID?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsContent
            Divider()
            footer
        }
        .frame(width: 620)
        .elevatedSurface(radius: AppTheme.Radius.large, elevation: .overlay)
        .task {
            await Task.yield()
            isSearchFocused = true
        }
        .onDisappear {
            session.clearMessageSearch()
        }
        .onChange(of: session.messageSearchState) {
            highlightedID = results.first?.id
        }
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                session.clearMessageSearch()
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            session.searchMessages(trimmed)
        }
        .onExitCommand(perform: dismiss)
        .onKeyPress(.downArrow) {
            moveHighlight(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveHighlight(by: -1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message search")
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.medium) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.Colors.secondaryText)

            TextField("Search all messages", text: $query)
                .textFieldStyle(.plain)
                .font(AppTheme.Typography.body)
                .focused($isSearchFocused)
                .onSubmit(openHighlightedResult)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Searching messages")
            }

            Text("esc")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Colors.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, AppTheme.Spacing.extraExtraSmall)
                .background(AppTheme.Colors.fillHover)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.extraSmall, style: .continuous))
        }
        .padding(.horizontal, AppTheme.Spacing.large)
        .frame(minHeight: 52)
    }

    @ViewBuilder
    private var resultsContent: some View {
        switch session.messageSearchState {
        case .idle:
            searchPlaceholder
        case .loading:
            VStack(spacing: AppTheme.Spacing.medium) {
                ProgressView()
                Text("Searching your Zulip history…")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        case let .loaded(_, results) where results.isEmpty:
            ContentUnavailableView(
                "No messages found",
                systemImage: "text.magnifyingglass",
                description: Text("Try different words or a broader query.")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        case let .loaded(_, results):
            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.extraSmall) {
                    ForEach(results) { result in
                        MessageSearchRow(
                            result: result,
                            isHighlighted: highlightedID == result.id
                        ) {
                            openResult(result)
                        }
                        .onHover { isHovered in
                            if isHovered {
                                highlightedID = result.id
                            }
                        }
                    }
                }
                .padding(AppTheme.Spacing.small)
            }
            .frame(maxHeight: 430)
        case let .failed(_, message):
            ContentUnavailableView {
                Label("Search unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    session.searchMessages(query)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        }
    }

    private var searchPlaceholder: some View {
        ContentUnavailableView(
            "Search messages",
            systemImage: "text.magnifyingglass",
            description: Text("Results come from your Zulip organization.")
        )
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var footer: some View {
        HStack {
            Label("Move", systemImage: "arrow.up.arrow.down")
            Label("Open message", systemImage: "return")
            Spacer()
            Text(resultCount == 1 ? "1 result" : "\(resultCount) results")
        }
        .font(AppTheme.Typography.caption)
        .foregroundStyle(AppTheme.Colors.tertiaryText)
        .padding(.horizontal, AppTheme.Spacing.large)
        .frame(minHeight: 34)
    }

    private var results: [MessageSearchResult] {
        guard case let .loaded(_, results) = session.messageSearchState else {
            return []
        }
        return results
    }

    private var resultCount: Int {
        results.count
    }

    private var isLoading: Bool {
        if case .loading = session.messageSearchState {
            return true
        }
        return false
    }

    private func moveHighlight(by offset: Int) {
        guard !results.isEmpty else {
            highlightedID = nil
            return
        }
        let currentIndex = results.firstIndex { $0.id == highlightedID } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), results.count - 1)
        highlightedID = results[nextIndex].id
    }

    private func openHighlightedResult() {
        guard let highlightedID,
              let result = results.first(where: { $0.id == highlightedID })
        else {
            return
        }
        openResult(result)
    }
}

private struct MessageSearchRow: View {
    let result: MessageSearchResult
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.medium) {
                Image(systemName: result.systemImage)
                    .font(AppTheme.Typography.scaled(13, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.extraSmall) {
                    HStack(spacing: AppTheme.Spacing.small) {
                        Text(result.title)
                            .font(AppTheme.Typography.calloutMedium)
                            .foregroundStyle(AppTheme.Colors.primaryText)
                            .lineLimit(1)

                        Text(result.subtitle)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                            .lineLimit(1)

                        Spacer()

                        Text(result.timestamp, style: .date)
                        Text(result.timestamp, style: .time)
                    }

                    Text(result.senderName)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Colors.secondaryText)

                    Text(result.contentPreview)
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(AppTheme.Colors.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if isHighlighted {
                    Image(systemName: "return")
                        .font(AppTheme.Typography.scaled(10))
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.medium)
            .padding(.vertical, AppTheme.Spacing.small)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.medium,
                    style: .continuous
                )
                .fill(isHighlighted ? AppTheme.Colors.accentSoft : .clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(result.title), \(result.senderName), \(result.contentPreview)"
        )
        .accessibilityHint("Open and focus this message")
    }
}
