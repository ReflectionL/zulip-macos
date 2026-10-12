import AppKit
import SwiftUI
import ZulipCoreBindings

struct MessageContentView: View {
    let blocks: [ContentBlock]
    var mediaLocalURLs: [String: String] = [:]
    var mediaFailures: [String: String] = [:]
    var requestMedia: ((String) -> Void)?
    var retryMedia: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                ContentBlockView(
                    block: block,
                    mediaLocalURLs: mediaLocalURLs,
                    mediaFailures: mediaFailures,
                    requestMedia: requestMedia,
                    retryMedia: retryMedia
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct ContentBlockView: View {
    let block: ContentBlock
    let mediaLocalURLs: [String: String]
    let mediaFailures: [String: String]
    let requestMedia: ((String) -> Void)?
    let retryMedia: ((String) -> Void)?

    @ViewBuilder
    var body: some View {
        switch block {
        case let .paragraph(content):
            InlineContentText(content: content)

        case let .heading(level, content):
            InlineContentText(content: content, font: Self.headingFont(level: level))
                .accessibilityAddTraits(.isHeader)

        case let .quote(blocks):
            HStack(alignment: .top, spacing: AppTheme.Spacing.medium) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(AppTheme.Colors.accent.opacity(0.7))
                    .frame(width: 3)

                AnyView(
                    MessageContentView(
                        blocks: blocks,
                        mediaLocalURLs: mediaLocalURLs,
                        mediaFailures: mediaFailures,
                        requestMedia: requestMedia,
                        retryMedia: retryMedia
                    )
                )
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            }
            .padding(.vertical, AppTheme.Spacing.extraSmall)
            .accessibilityLabel("Quote, \(blocks.map(\.plainText).joined(separator: " "))")

        case let .list(items, ordered):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: AppTheme.Spacing.small) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(AppTheme.Typography.bodyEmphasized)
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                            .frame(width: 20, alignment: .trailing)

                        AnyView(
                            MessageContentView(
                                blocks: item,
                                mediaLocalURLs: mediaLocalURLs,
                                mediaFailures: mediaFailures,
                                requestMedia: requestMedia,
                                retryMedia: retryMedia
                            )
                        )
                    }
                }
            }
            .accessibilityLabel(
                "\(ordered ? "Numbered" : "Bulleted") list, \(items.count) items"
            )

        case let .code(language, value):
            VStack(alignment: .leading, spacing: 0) {
                if let language {
                    Text(language.uppercased())
                        .font(AppTheme.Typography.eyebrow)
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                        .padding(.horizontal, AppTheme.Spacing.medium)
                        .padding(.top, AppTheme.Spacing.small)
                }

                ScrollView(.horizontal) {
                    Text(value)
                        .font(AppTheme.Typography.code)
                        .foregroundStyle(AppTheme.Colors.primaryText)
                        .textSelection(.enabled)
                        .padding(AppTheme.Spacing.medium)
                }
            }
            .background(AppTheme.Colors.sidebar)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: AppTheme.Metrics.controlRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: AppTheme.Metrics.controlRadius,
                    style: .continuous
                )
                .stroke(AppTheme.Colors.subtleStroke, lineWidth: 1)
            }
            .accessibilityLabel("Code\(language.map { ", \($0)" } ?? ""), \(value)")

        case let .image(url, alt, width, height):
            NativeImageBlock(
                url: url,
                alt: alt,
                width: width,
                height: height,
                localURL: mediaLocalURLs[url],
                failure: mediaFailures[url],
                requestMedia: requestMedia,
                retryMedia: retryMedia
            )

        case let .unsupported(summary):
            Label(summary, systemImage: "doc.questionmark")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .padding(AppTheme.Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.Colors.sidebar)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppTheme.Metrics.controlRadius,
                        style: .continuous
                    )
                )
                .accessibilityLabel("Unsupported content, \(summary)")
        }
    }
}

extension ContentBlockView {
    static func headingFont(level: Int) -> Font {
        switch level {
        case 1: .system(size: 22, weight: .semibold)
        case 2: .system(size: 19, weight: .semibold)
        case 3: .system(size: 16.5, weight: .semibold)
        default: .system(size: 14, weight: .semibold)
        }
    }
}

private struct InlineContentText: View {
    let content: [InlineContent]
    var font: Font = AppTheme.Typography.body

    var body: some View {
        Text(attributedContent)
            .font(font)
            .foregroundStyle(AppTheme.Colors.primaryText)
            .tint(AppTheme.Colors.accent)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributedContent: AttributedString {
        Self.attributed(content, inherited: [])
    }

    private static func attributed(
        _ items: [InlineContent],
        inherited: InlinePresentationIntent
    ) -> AttributedString {
        items.reduce(into: AttributedString()) { result, item in
            var fragment: AttributedString

            switch item {
            case let .styled(style, children):
                fragment = attributed(children, inherited: inherited.union(intent(for: style)))
                if style == .code {
                    fragment.backgroundColor = AppTheme.Colors.hover
                }
            case .text, .emoji:
                fragment = AttributedString(item.plainText)
            case let .link(label, url):
                fragment = AttributedString(label)
                fragment.link = URL(string: url)
                fragment.foregroundColor = AppTheme.Colors.accent
                fragment.underlineStyle = .single
            case .mention:
                fragment = AttributedString(item.plainText)
                fragment.foregroundColor = AppTheme.Colors.accent
                fragment.font = .system(size: 14, weight: .semibold)
            }

            if !inherited.isEmpty, !isStyled(item) {
                fragment.inlinePresentationIntent = inherited
            }
            result.append(fragment)
        }
    }

    private static func isStyled(_ item: InlineContent) -> Bool {
        if case .styled = item { return true }
        return false
    }

    private static func intent(for style: InlineStyle) -> InlinePresentationIntent {
        switch style {
        case .strong: .stronglyEmphasized
        case .emphasis: .emphasized
        case .strikethrough: .strikethrough
        case .code: .code
        }
    }
}

private struct NativeImageBlock: View {
    let url: String
    let alt: String
    let width: Int?
    let height: Int?
    let localURL: String?
    let failure: String?
    let requestMedia: ((String) -> Void)?
    let retryMedia: ((String) -> Void)?

    @State private var nativeImage: NSImage?
    @State private var decodeFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            ZStack {
                if let nativeImage {
                    Image(nsImage: nativeImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    LinearGradient(
                        colors: [
                            AppTheme.Colors.accent.opacity(0.45),
                            AppTheme.Colors.sidebar,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    if url.hasPrefix("fixture://") {
                        VStack(spacing: AppTheme.Spacing.medium) {
                            Image(systemName: "macwindow")
                                .font(.system(size: 34, weight: .light))
                            Text("Zulip Mac")
                                .font(.system(size: 20, weight: .semibold))
                            Text("Native conversation surface")
                                .font(AppTheme.Typography.metadata)
                        }
                        .foregroundStyle(AppTheme.Colors.primaryText)
                    } else if let failure {
                        VStack(spacing: AppTheme.Spacing.small) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(failure).lineLimit(2)
                            Button("Retry") { retryMedia?(url) }
                                .buttonStyle(.borderless)
                        }
                        .font(AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Colors.destructive)
                        .padding()
                    } else if decodeFailed {
                        Label("Image could not be decoded", systemImage: "photo.badge.exclamationmark")
                            .font(AppTheme.Typography.metadata)
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: 520)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: AppTheme.Metrics.panelRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: AppTheme.Metrics.panelRadius,
                    style: .continuous
                )
                .stroke(AppTheme.Colors.subtleStroke, lineWidth: 1)
            }

            Text(alt)
                .font(AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Colors.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Image, \(alt)")
        .task(id: localURL) {
            guard !url.hasPrefix("fixture://") else { return }
            guard let localURL,
                  let fileURL = URL(string: localURL),
                  fileURL.isFileURL
            else {
                requestMedia?(url)
                return
            }
            decodeFailed = false
            let decoded = await NativeImageDecoder.load(fileURL)
            guard !Task.isCancelled else { return }
            nativeImage = decoded.image
            decodeFailed = decoded.image == nil
        }
    }

    private var aspectRatio: CGFloat {
        guard let width, let height, height > 0 else {
            return 16 / 9
        }
        return CGFloat(width) / CGFloat(height)
    }
}

struct SendableNativeImage: @unchecked Sendable {
    let image: NSImage?
}

enum NativeImageDecoder {
    nonisolated static func load(_ fileURL: URL) async -> SendableNativeImage {
        await Task.detached(priority: .utility) {
            guard fileURL.isFileURL else {
                return SendableNativeImage(image: nil)
            }
            return SendableNativeImage(image: NSImage(contentsOf: fileURL))
        }.value
    }
}

enum ContentSnapshot {
    static func describe(_ blocks: [ContentBlock]) -> String {
        blocks.map(describe).joined(separator: "\n")
    }

    private static func describe(_ block: ContentBlock) -> String {
        switch block {
        case let .paragraph(content):
            "paragraph(\(content.map(describe).joined(separator: "|")))"
        case let .quote(blocks):
            "quote{\(describe(blocks))}"
        case let .list(items, ordered):
            "list[\(ordered ? "ordered" : "unordered")]{"
                + items.map(describe).joined(separator: ";")
                + "}"
        case let .code(language, value):
            "code[\(language ?? "plain")](\(value))"
        case let .image(url, alt, width, height):
            "image(\(url),\(alt),\(width ?? 0)x\(height ?? 0))"
        case let .unsupported(summary):
            "unsupported(\(summary))"
        }
    }

    private static func describe(_ inline: InlineContent) -> String {
        switch inline {
        case let .text(value):
            "text:\(value)"
        case let .link(label, url):
            "link:\(label)<\(url)>"
        case let .mention(displayName, userID):
            "mention:\(displayName)#\(userID)"
        case let .emoji(name, value):
            "emoji:\(name)=\(value)"
        }
    }
}

#Preview("Native message content") {
    ScrollView {
        MessageContentView(blocks: FixtureContent.allBlocks)
            .padding()
    }
    .frame(width: 660, height: 720)
    .background(AppTheme.Colors.canvas)
}
