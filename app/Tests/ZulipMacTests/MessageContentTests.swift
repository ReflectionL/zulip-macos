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
        #expect(snapshot.contains("unsupported("))
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
}
