import Testing
import UniformTypeIdentifiers
@testable import ZulipMac

@Suite("Dropped files")
struct DroppedFilesTests {
    @Test("The conversation accepts files and pictures")
    func acceptedTypes() {
        #expect(DroppedFiles.acceptedTypes.contains(.fileURL))
        #expect(DroppedFiles.acceptedTypes.contains(.image))
    }

    @Test("A screenshot name that ends in a time gets the picture's extension")
    func screenshotNameGetsExtension() {
        let name = DroppedFiles.fileName(
            suggested: "Screenshot 2026-11-02 at 11.53.01",
            type: .png
        )
        #expect(name == "Screenshot 2026-11-02 at 11.53.01.png")
    }

    @Test("A name that already has the right extension is kept")
    func keepsMatchingExtension() {
        #expect(DroppedFiles.fileName(suggested: "photo.png", type: .png) == "photo.png")
    }

    @Test("A missing or unusable name falls back to a plain one")
    func fallsBackWhenNameIsMissing() {
        #expect(DroppedFiles.fileName(suggested: nil, type: .png) == "Image.png")
        #expect(DroppedFiles.fileName(suggested: "  ", type: .png) == "Image.png")
    }

    @Test("A suggested name cannot point outside the drop folder")
    func dropsPathComponents() {
        let name = DroppedFiles.fileName(suggested: "../../etc/passwd", type: .png)
        #expect(!name.contains("/"))
    }
}
