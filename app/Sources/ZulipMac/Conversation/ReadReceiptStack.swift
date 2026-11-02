import SwiftUI

/// Small overlapping round avatars of the people who have read a message, ending
/// in a "+N" chip when there are more than fit.
struct ReadReceiptStack: View {
    let readers: [ReadReceiptReader]
    var avatarSize: CGFloat = 16
    var mediaLocalURLs: [String: String] = [:]
    var requestMedia: ((String) -> Void)?

    nonisolated private static let ringWidth: CGFloat = 1.5

    /// Each avatar covers about a third of its neighbour.
    private var overlap: CGFloat {
        -(avatarSize + Self.ringWidth * 2) / 3
    }

    /// How wide the stack is for `readerCount` readers, so a line of text can
    /// leave room for it.
    nonisolated static func width(readerCount: Int, avatarSize: CGFloat) -> CGFloat {
        let visible = min(readerCount, ReadReceiptPolicy.visibleReaderLimit)
        let items = visible + (readerCount > visible ? 1 : 0)
        guard items > 0 else { return 0 }
        let item = avatarSize + ringWidth * 2
        return item + CGFloat(items - 1) * item * 2 / 3
    }

    var body: some View {
        let visible = Array(readers.prefix(ReadReceiptPolicy.visibleReaderLimit))
        let hiddenCount = readers.count - visible.count
        HStack(spacing: overlap) {
            ForEach(visible) { reader in
                AvatarImage(
                    initials: reader.initials,
                    remoteURL: reader.avatarURL,
                    size: avatarSize,
                    mediaLocalURLs: mediaLocalURLs,
                    requestMedia: requestMedia
                )
                .padding(Self.ringWidth)
                .background(Circle().fill(AppTheme.Colors.canvas))
            }
            if hiddenCount > 0 {
                Text("+\(hiddenCount)")
                    .font(AppTheme.Typography.scaled(8).weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: avatarSize, height: avatarSize)
                    .background(Circle().fill(AppTheme.Colors.fillHover))
                    .padding(Self.ringWidth)
                    .background(Circle().fill(AppTheme.Colors.canvas))
            }
        }
        .help(summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        "Read by " + readers.map(\.name).formatted(.list(type: .and))
    }
}
