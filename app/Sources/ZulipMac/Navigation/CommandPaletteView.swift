import SwiftUI
import ZulipCoreBindings

struct CommandPaletteView: View {
    @Bindable var navigation: NavigationStore

    @FocusState private var isSearchFocused: Bool
    @State private var highlightedKey: ConversationKey?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.medium) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.Colors.secondaryText)

                TextField("Search channels, topics, and people", text: $navigation.query)
                    .textFieldStyle(.plain)
                    .font(AppTheme.Typography.body)
                    .focused($isSearchFocused)
                    .onSubmit(openHighlightedResult)

                Text("esc")
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Colors.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(AppTheme.Colors.hover)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .padding(.horizontal, AppTheme.Spacing.large)
            .frame(height: 52)

            Divider()

            if navigation.searchResults.isEmpty {
                ContentUnavailableView(
                    "No conversations",
                    systemImage: "magnifyingglass",
                    description: Text("Try another channel, topic, or person.")
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                ScrollView {
                    LazyVStack(spacing: AppTheme.Spacing.extraSmall) {
                        ForEach(navigation.searchResults) { destination in
                            CommandPaletteRow(
                                destination: destination,
                                isHighlighted: highlightedKey == destination.key
                            ) {
                                navigation.select(destination.key)
                            }
                            .onHover { isHovered in
                                if isHovered {
                                    highlightedKey = destination.key
                                }
                            }
                        }
                    }
                    .padding(AppTheme.Spacing.small)
                }
                .frame(maxHeight: 380)
            }

            Divider()

            HStack {
                Label("Move", systemImage: "arrow.up.arrow.down")
                Label("Open", systemImage: "return")
                Spacer()
                Text("\(navigation.searchResults.count) results")
            }
            .font(AppTheme.Typography.metadata)
            .foregroundStyle(AppTheme.Colors.tertiaryText)
            .padding(.horizontal, AppTheme.Spacing.large)
            .frame(height: 34)
        }
        .frame(width: 560)
        .elevatedSurface(radius: 14)
        .shadow(color: .black.opacity(0.28), radius: 32, y: 16)
        .onAppear {
            isSearchFocused = true
            highlightedKey = navigation.searchResults.first?.key
        }
        .onChange(of: navigation.query) {
            highlightedKey = navigation.searchResults.first?.key
        }
        .onExitCommand {
            navigation.dismissCommandPalette()
        }
        .onKeyPress(.downArrow) {
            moveHighlight(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveHighlight(by: -1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick switcher")
    }

    private func moveHighlight(by offset: Int) {
        let results = navigation.searchResults
        guard !results.isEmpty else {
            highlightedKey = nil
            return
        }

        let currentIndex = results.firstIndex { $0.key == highlightedKey } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), results.count - 1)
        highlightedKey = results[nextIndex].key
    }

    private func openHighlightedResult() {
        guard let highlightedKey else {
            return
        }
        navigation.select(highlightedKey)
    }
}
private struct CommandPaletteRow: View {
    let destination: NavigationDestination
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.medium) {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.title)
                        .font(AppTheme.Typography.sidebarEmphasized)
                        .foregroundStyle(AppTheme.Colors.primaryText)
                    Text(destination.subtitle)
                        .font(AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }

                Spacer()

                if isHighlighted {
                    Image(systemName: "return")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.medium)
            .frame(height: 46)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(
                    cornerRadius: AppTheme.Metrics.controlRadius,
                    style: .continuous
                )
                .fill(isHighlighted ? AppTheme.Colors.selection : .clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(destination.title), \(destination.subtitle)")
    }
}
