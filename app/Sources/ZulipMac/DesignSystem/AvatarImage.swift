import AppKit
import SwiftUI

/// A rounded avatar backed by a file in the Rust media cache.
///
/// The image is requested on demand through `requestMedia`; until it arrives,
/// or when none exists, the initials stay visible.
struct AvatarImage: View {
    let initials: String
    let remoteURL: String?
    let size: CGFloat
    var cornerRadius: CGFloat?
    var fallbackFill: Color = AppTheme.Colors.hover
    var fallbackForeground: Color = AppTheme.Colors.primaryText
    var mediaLocalURLs: [String: String] = [:]
    var requestMedia: ((String) -> Void)?

    @State private var image: NSImage?

    private var localURL: String? {
        remoteURL.flatMap { mediaLocalURLs[$0] }
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallbackFill
                Text(initials)
                    .font(.system(size: max(size * 0.42, 7), weight: .semibold))
                    .foregroundStyle(fallbackForeground)
            }
        }
        .frame(width: size, height: size)
        .clipShape(
            RoundedRectangle(
                cornerRadius: cornerRadius ?? size / 2,
                style: .continuous
            )
        )
        .accessibilityHidden(true)
        .task(id: "\(remoteURL ?? "")|\(localURL ?? "")") {
            guard let remoteURL, !remoteURL.isEmpty else {
                image = nil
                return
            }
            guard let localURL,
                  let fileURL = URL(string: localURL),
                  fileURL.isFileURL
            else {
                requestMedia?(remoteURL)
                return
            }
            let decoded = await NativeImageDecoder.load(fileURL)
            guard !Task.isCancelled else { return }
            image = decoded.image
        }
    }
}
