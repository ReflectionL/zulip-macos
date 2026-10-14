import AppKit
import CryptoKit
import LinkPresentation
import SwiftUI
import UniformTypeIdentifiers

enum LinkPreviewSettings {
    /// Whether the app may load a linked page to describe it.
    static let loadsPreviewsKey = "loadsLinkPreviews"
}

/// A card for a web page, like a link in Messages: picture, title, description
/// and site. The server's preview is shown as it is; for a link sent on its own
/// the app may load the page with LinkPresentation to fill the card in.
struct LinkPreviewCard: View {
    let url: String
    let title: String?
    let description: String?
    let imageURL: String?
    let fromServer: Bool
    /// The cached copy of the server's preview picture.
    let localImageURL: String?
    let requestMedia: ((String) -> Void)?

    @AppStorage(LinkPreviewSettings.loadsPreviewsKey) private var loadsPreviews = true
    @State private var fetched: FetchedLinkMetadata?
    @State private var image: NSImage?

    private var pageURL: URL? {
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            return nil
        }
        return parsed
    }

    private var site: String {
        guard let host = pageURL?.host(percentEncoded: false), !host.isEmpty else {
            return url
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var shownTitle: String {
        fetched?.title ?? title ?? site
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image {
                Color.clear
                    .frame(height: Self.imageHeight)
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(shownTitle)
                    .font(AppTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.Colors.primaryText)
                    .lineLimit(2)
                if let description {
                    Text(description)
                        .font(AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                        .lineLimit(3)
                }
                Text(site)
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Colors.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, AppTheme.Spacing.medium)
            .padding(.vertical, AppTheme.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: Self.maximumWidth, alignment: .leading)
        .background(AppTheme.Colors.sidebar)
        .clipShape(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.panelRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Metrics.panelRadius, style: .continuous)
                .stroke(AppTheme.Colors.subtleStroke, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help(url)
        .contextMenu {
            Button("Open Link", action: open)
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Link, \(shownTitle), \(site)")
        .accessibilityAddTraits(.isLink)
        .accessibilityAction { open() }
        .task(id: localImageURL) {
            await loadServerImage()
        }
        .task(id: loadsPreviews) {
            await describePage()
        }
    }

    private static let maximumWidth: CGFloat = 360
    private static let imageHeight: CGFloat = 170

    private func open() {
        guard let pageURL else { return }
        NSWorkspace.shared.open(pageURL)
    }

    private func loadServerImage() async {
        guard let imageURL else { return }
        guard let localImageURL,
              let fileURL = URL(string: localImageURL),
              fileURL.isFileURL
        else {
            requestMedia?(imageURL)
            return
        }
        let decoded = await NativeImageDecoder.load(fileURL)
        guard !Task.isCancelled, let decoded = decoded.image else { return }
        image = decoded
    }

    /// Fills in a link sent on its own from the page itself, when allowed.
    private func describePage() async {
        guard !fromServer, loadsPreviews, fetched == nil, let pageURL else { return }
        guard let metadata = await LinkMetadataStore.shared.metadata(for: pageURL),
              !Task.isCancelled
        else {
            return
        }
        fetched = metadata
        guard image == nil, let fileURL = metadata.imageFileURL else { return }
        let decoded = await NativeImageDecoder.load(fileURL)
        guard !Task.isCancelled, let decoded = decoded.image else { return }
        image = decoded
    }
}

/// What the app learned about a web page by loading it.
struct FetchedLinkMetadata: Equatable, Sendable {
    let title: String?
    /// A cached copy of the page's preview picture.
    let imageFileURL: URL?
}

/// Page descriptions loaded with LinkPresentation, shared by every card, and
/// loaded at most once per page while the app runs.
@MainActor
final class LinkMetadataStore {
    static let shared = LinkMetadataStore()

    /// `nil` values record pages that could not be described.
    private var results: [URL: FetchedLinkMetadata?] = [:]
    private var inFlight: [URL: Task<FetchedLinkMetadata?, Never>] = [:]

    func metadata(for url: URL) async -> FetchedLinkMetadata? {
        if let known = results[url] {
            return known
        }
        if let task = inFlight[url] {
            return await task.value
        }
        let task = Task { await Self.fetch(url) }
        inFlight[url] = task
        let value = await task.value
        inFlight[url] = nil
        if results.count > Self.maximumEntries {
            results.removeAll()
        }
        results[url] = .some(value)
        return value
    }

    private static let maximumEntries = 500
    private nonisolated static let maximumImageBytes = 8 * 1_048_576

    private static func fetch(_ url: URL) async -> FetchedLinkMetadata? {
        await withCheckedContinuation { continuation in
            // Runs here on the main thread, where LinkPresentation is started.
            startFetching(url, provider: ProviderBox(), continuation: continuation)
        }
    }

    /// Built outside the main actor so that the completion handlers, which
    /// LinkPresentation calls on a background queue, are not main-actor isolated.
    private nonisolated static func startFetching(
        _ url: URL,
        provider box: ProviderBox,
        continuation: CheckedContinuation<FetchedLinkMetadata?, Never>
    ) {
        box.provider.timeout = 15
        box.provider.startFetchingMetadata(for: url) { metadata, error in
            withExtendedLifetime(box) {}
            guard let metadata, error == nil else {
                continuation.resume(returning: nil)
                return
            }
            let title = metadata.title?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let shownTitle = title?.isEmpty == false ? title : nil
            guard let imageProvider = metadata.imageProvider else {
                continuation.resume(
                    returning: FetchedLinkMetadata(title: shownTitle, imageFileURL: nil)
                )
                return
            }
            _ = imageProvider.loadDataRepresentation(
                forTypeIdentifier: UTType.image.identifier
            ) { data, _ in
                let file = data.flatMap { cachePreviewImage($0, for: url) }
                continuation.resume(
                    returning: FetchedLinkMetadata(title: shownTitle, imageFileURL: file)
                )
            }
        }
    }

    /// Writes a page's preview picture to the temporary directory, named after
    /// the page, so the card can decode it like any cached picture.
    private nonisolated static func cachePreviewImage(_ data: Data, for url: URL) -> URL? {
        guard !data.isEmpty, data.count <= maximumImageBytes else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZulipMacLinkPreviews", isDirectory: true)
        let name = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let file = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
}

/// Keeps a metadata provider alive until its completion handler runs.
private final class ProviderBox: @unchecked Sendable {
    let provider = LPMetadataProvider()
}

struct LinkPreviewSettingsSection: View {
    @AppStorage(LinkPreviewSettings.loadsPreviewsKey) private var loadsPreviews = true

    var body: some View {
        Section("Link Previews") {
            Toggle("Load previews of linked pages", isOn: $loadsPreviews)
            Text(
                "A link sent on its own is shown as a card. When Zulip has no preview "
                    + "of the page, Zulip Mac loads the page to describe it, so the "
                    + "website can see your IP address."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
