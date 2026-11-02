import CoreGraphics
import Testing
@testable import ZulipMac

@Suite("Read receipt layout")
struct ReadReceiptLayoutTests {
    @Test("The room left at the end of a line fits the receipts shown in it")
    func stackWidth() {
        // Each avatar has a 1.5 pt ring and covers a third of the one before it.
        #expect(ReadReceiptStack.width(readerCount: 0, avatarSize: 14) == 0)
        #expect(ReadReceiptStack.width(readerCount: 1, avatarSize: 14) == 17)
        #expect(ReadReceiptStack.width(readerCount: 2, avatarSize: 14) == 17 + 17 * 2 / 3)
        // Four avatars, then one "+N" chip however many more there are.
        let limit = ReadReceiptPolicy.visibleReaderLimit
        #expect(
            ReadReceiptStack.width(readerCount: limit + 1, avatarSize: 14)
                == ReadReceiptStack.width(readerCount: limit + 9, avatarSize: 14)
        )
        #expect(
            ReadReceiptStack.width(readerCount: limit + 1, avatarSize: 14)
                > ReadReceiptStack.width(readerCount: limit, avatarSize: 14)
        )
    }
}
