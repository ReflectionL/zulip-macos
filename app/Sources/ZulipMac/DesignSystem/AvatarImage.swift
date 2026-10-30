import AppKit
import SwiftUI

/// Decoded avatars kept in memory, so a row that is rebuilt (scrolling, switching
/// conversations) paints its picture at once instead of flashing the initials.
@MainActor
enum AvatarImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    static func image(for localURL: String?) -> NSImage? {
        localURL.flatMap { cache.object(forKey: $0 as NSString) }
    }

    static func store(_ image: NSImage, for localURL: String) {
        cache.setObject(image, forKey: localURL as NSString)
    }
}

/// A rounded avatar backed by a file in the Rust media cache.
///
/// The image is requested on demand through `requestMedia`; until it arrives,
/// or when none exists, the initials stay visible.
struct AvatarImage: View {
    let initials: String
    let remoteURL: String?
    let size: CGFloat
    var cornerRadius: CGFloat?
    var fallbackFill: Color = AppTheme.Colors.fillPressed
    var fallbackForeground: Color = AppTheme.Colors.primaryText
    var mediaLocalURLs: [String: String] = [:]
    var requestMedia: ((String) -> Void)?

    @State private var image: NSImage?

    private var localURL: String? {
        remoteURL.flatMap { mediaLocalURLs[$0] }
    }

    var body: some View {
        ZStack {
            if let displayed = image ?? AvatarImageCache.image(for: localURL) {
                Image(nsImage: displayed)
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
            if AvatarImageCache.image(for: localURL) != nil {
                return
            }
            let decoded = await NativeImageDecoder.load(fileURL, maxPixelSize: 160)
            guard !Task.isCancelled else { return }
            if let decodedImage = decoded.image {
                AvatarImageCache.store(decodedImage, for: localURL)
            }
            image = decoded.image
        }
    }
}
