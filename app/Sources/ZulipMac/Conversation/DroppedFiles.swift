import Foundation
import UniformTypeIdentifiers

/// Turns what the user dropped on a conversation into local files to upload.
///
/// A file dragged from Finder carries a file address. A Mac screenshot dragged
/// from its floating thumbnail, or a picture dragged from another app, carries
/// the picture itself instead, so an address-only drop target refuses it until
/// the file has been saved somewhere.
enum DroppedFiles {
    /// What the conversation accepts: files, and pictures that are not files yet.
    static let acceptedTypes: [UTType] = [.fileURL, .image]

    /// The files behind `providers`, in drop order. A provider that offers neither
    /// a local file nor a picture is skipped.
    @MainActor
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await fileURL(from: provider) {
                urls.append(url)
            } else if let url = await copiedPicture(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    /// The name a dropped picture is uploaded under: the name the source gave
    /// it, with the extension its type uses when that is missing, because the
    /// server picks the preview from the extension.
    nonisolated static func fileName(suggested: String?, type: UTType) -> String {
        let proposed = suggested.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let base = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, base != "/" else {
            return ["Image", type.preferredFilenameExtension].compactMap { $0 }.joined(separator: ".")
        }
        // "Screenshot 2026-11-02 at 11.53.01" ends in ".01", which is not an extension.
        let current = (base as NSString).pathExtension
        if !current.isEmpty, UTType(filenameExtension: current)?.conforms(to: type) == true {
            return base
        }
        guard let preferred = type.preferredFilenameExtension else {
            return base
        }
        return "\(base).\(preferred)"
    }

    /// Main-actor isolated like `urls(from:)`, so the provider, which is not
    /// `Sendable`, never leaves the actor; only its results cross back.
    @MainActor
    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            // `@Sendable`, so the callback (which runs on a background queue) is
            // not taken to belong to the main actor.
            _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in
                continuation.resume(returning: url.flatMap { $0.isFileURL ? $0 : nil })
            }
        }
    }

    /// Copies the picture the provider offers into a folder of its own: the file
    /// the system hands over is deleted as soon as the callback returns.
    @MainActor
    private static func copiedPicture(from provider: NSItemProvider) async -> URL? {
        guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) })
        else {
            return nil
        }
        let name = fileName(suggested: provider.suggestedName, type: type)
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { @Sendable source, _ in
                continuation.resume(returning: source.flatMap { copy($0, as: name) })
            }
        }
    }

    private nonisolated static func copy(_ source: URL, as name: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZulipMacDrops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
