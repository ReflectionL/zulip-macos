import SwiftUI
import ZulipCoreBindings

/// The emoji already on a message, as chips with a count. Clicking one adds or
/// withdraws the user's own reaction; a highlighted chip is one the user used.
struct ReactionChips: View {
    let reactions: [MessageReaction]
    let isDisabled: Bool
    let react: (ReactionTarget) -> Void

    var body: some View {
        WrappingHStack(spacing: AppTheme.Spacing.extraSmall) {
            ForEach(reactions) { reaction in
                Button {
                    react(reaction.target)
                } label: {
                    HStack(spacing: 4) {
                        Text(Self.glyph(for: reaction))
                        Text("\(reaction.count)")
                            .monospacedDigit()
                    }
                    .font(AppTheme.Typography.metadata)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(
                        reaction.includesMe
                            ? AppTheme.Colors.accent.opacity(0.18)
                            : AppTheme.Colors.hover
                    )
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                AppTheme.Colors.accent.opacity(reaction.includesMe ? 0.7 : 0),
                                lineWidth: 1
                            )
                    }
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .help(":\(reaction.emojiName):")
                .accessibilityLabel(
                    "\(reaction.emojiName), \(reaction.count) "
                        + (reaction.count == 1 ? "reaction" : "reactions")
                        + (reaction.includesMe ? ", including yours" : "")
                )
                .accessibilityHint(reaction.includesMe ? "Removes your reaction" : "Adds your reaction")
            }
        }
    }

    /// Unicode emoji draw from their code; custom emoji, which have no glyph here,
    /// show their name.
    static func glyph(for reaction: MessageReaction) -> String {
        if reaction.reactionType.isEmpty || reaction.reactionType == "unicode_emoji",
           let glyph = EmojiCatalog.glyph(forCode: reaction.emojiCode)
        {
            return glyph
        }
        if reaction.reactionType.isEmpty,
           let entry = EmojiCatalog.all.first(where: { $0.name == reaction.emojiName })
        {
            return entry.glyph
        }
        return ":\(reaction.emojiName):"
    }
}

/// The popover behind a message's "React" button: a row of recommended emoji, and a
/// searchable grid of every emoji. A chosen emoji is reported once and the popover closes.
struct ReactionPicker: View {
    let existing: [MessageReaction]
    let choose: (ReactionTarget) -> Void

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private static let columns = Array(
        repeating: GridItem(.fixed(34), spacing: 2),
        count: 10
    )

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            Text("Quick reactions")
                .font(AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Colors.secondaryText)
            HStack(spacing: 2) {
                ForEach(EmojiCatalog.recommended) { entry in
                    emojiButton(entry, size: 22)
                }
            }

            Divider()

            TextField("Search emoji, or paste one", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .accessibilityLabel("Search emoji")

            let results = EmojiCatalog.search(query)
            if results.isEmpty {
                Text("No matching emoji")
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVGrid(columns: Self.columns, spacing: 2) {
                        ForEach(results) { entry in
                            emojiButton(entry, size: 22)
                        }
                    }
                }
                .frame(height: 220)
            }
        }
        .padding(AppTheme.Spacing.medium)
        .frame(width: 10 * 34 + 9 * 2 + 2 * AppTheme.Spacing.medium)
        .onAppear { isSearchFocused = true }
    }

    private func emojiButton(_ entry: EmojiCatalog.Entry, size: CGFloat) -> some View {
        let used = existing.contains { entry.target.matches($0) && $0.includesMe }
        return Button {
            choose(entry.target)
        } label: {
            Text(entry.glyph)
                .font(.system(size: size))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(used ? AppTheme.Colors.accent.opacity(0.2) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(":\(entry.name):")
        .accessibilityLabel(entry.name.replacingOccurrences(of: "_", with: " "))
    }
}

/// Lays chips out left to right and starts a new line when a row is full.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let arrangement = arrange(in: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, arrangement.origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(
        in width: CGFloat,
        subviews: Subviews
    ) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), origins)
    }
}
