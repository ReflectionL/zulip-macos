import SwiftUI

/// Small overlapping round avatars of the people who have read a message, ending
/// in a "+N" chip when there are more than fit.
struct ReadReceiptStack: View {
    let readers: [ReadReceiptReader]
    var mediaLocalURLs: [String: String] = [:]
    var requestMedia: ((String) -> Void)?

    private static let avatarSize: CGFloat = 16
    private static let ringWidth: CGFloat = 1.5

    /// Each avatar covers about a third of its neighbour.
    private static var overlap: CGFloat {
        -(avatarSize + ringWidth * 2) / 3
    }

    var body: some View {
        let visible = Array(readers.prefix(ReadReceiptPolicy.visibleReaderLimit))
        let hiddenCount = readers.count - visible.count
        HStack(spacing: Self.overlap) {
            ForEach(visible) { reader in
                AvatarImage(
                    initials: reader.initials,
                    remoteURL: reader.avatarURL,
                    size: Self.avatarSize,
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
                    .frame(width: Self.avatarSize, height: Self.avatarSize)
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
