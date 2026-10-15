import AppKit
import Foundation
import SwiftUI
import Testing
import ZulipCoreBindings
@testable import ZulipMac

@Suite("Native message content")
struct MessageContentTests {
    @Test("The semantic content snapshot covers every native block")
    func semanticSnapshot() {
        let snapshot = ContentSnapshot.describe(FixtureContent.allBlocks)

        #expect(snapshot.contains("link:safe links<https://zulip.com/help/format-your-message-using-markdown>"))
        #expect(snapshot.contains("mention:Maya Chen#101"))
        #expect(snapshot.contains("emoji:zulip=🦓"))
        #expect(snapshot.contains("quote{"))
        #expect(snapshot.contains("list[unordered]"))
        #expect(snapshot.contains("list[ordered]"))
        #expect(snapshot.contains("code[rust]"))
        #expect(snapshot.contains("image(fixture://native-preview"))
        #expect(snapshot.contains("card[server](https://zulip.com/help/,Zulip help center"))
        #expect(snapshot.contains("table[3]("))
        #expect(snapshot.contains("math[inline]:E = mc^2"))
        #expect(snapshot.contains("math(\\int_0^1"))
        #expect(snapshot.contains("unsupported("))
    }

    @Test("A formula copies as the TeX Zulip understands")
    func mathText() {
        let inline = InlineContent.math(tex: "x^2", text: "𝑥²", display: false)
        #expect(inline.plainText == "$$x^2$$")

        let block = ContentBlock.math(tex: #"\frac{a}{b}"#, nodes: [])
        #expect(block.plainText == "```math\n\\frac{a}{b}\n```")
    }

    @Test("A table reads as its rows, cells joined by bars")
    func tableText() {
        let table = ContentBlock.table(
            alignments: [.leading, .trailing],
            header: [[.text("Name")], [.text("Count")]],
            rows: [[[.text("Maya")], [.text("3")]]]
        )
        #expect(table.plainText == "Name | Count\nMaya | 3")

        let headerless = ContentBlock.table(
            alignments: [.leading],
            header: [],
            rows: [[[.text("a")]], [[.text("b")]]]
        )
        #expect(headerless.plainText == "a\nb")
    }

    @Test("A link card reads as its title, or its address without one")
    func linkCardText() {
        let titled = ContentBlock.linkPreview(
            url: "https://example.com/post",
            title: "A post",
            description: nil,
            imageURL: nil,
            fromServer: false
        )
        let bare = ContentBlock.linkPreview(
            url: "https://example.com/post",
            title: nil,
            description: nil,
            imageURL: nil,
            fromServer: false
        )
        #expect(titled.plainText == "A post")
        #expect(bare.plainText == "https://example.com/post")
    }

    @Test("The complete content fixture renders in light and dark appearances")
    @MainActor
    func renderedSnapshots() {
        let lightRenderer = ImageRenderer(
            content: MessageContentView(blocks: FixtureContent.allBlocks)
                .frame(width: 640)
                .padding()
                .environment(\.colorScheme, .light)
        )
        let darkRenderer = ImageRenderer(
            content: MessageContentView(blocks: FixtureContent.allBlocks)
                .frame(width: 640)
                .padding()
                .environment(\.colorScheme, .dark)
        )

        #expect(lightRenderer.nsImage?.size.width == 672)
        #expect(darkRenderer.nsImage?.size.width == 672)
        #expect((lightRenderer.nsImage?.size.height ?? 0) > 400)
        #expect((darkRenderer.nsImage?.size.height ?? 0) > 400)
    }

    @Test("Cache-owned file URLs decode natively off the main actor")
    @MainActor
    func nativeImageDecode() async throws {
        let png = try #require(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zulip-native-image-\(UUID().uuidString).png")
        try png.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let decoded = await NativeImageDecoder.load(fileURL)
        #expect(decoded.image != nil)
        #expect(decoded.image?.size.width == 1)
        let rejected = await NativeImageDecoder.load(URL(string: "https://example.com/a.png")!)
        #expect(rejected.image == nil)
    }
}
