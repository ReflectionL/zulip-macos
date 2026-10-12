import AppKit
import CryptoKit
import Foundation

struct PreparedUpdate: Equatable, Sendable {
    /// The verified replacement bundle, staged beside the installed app so the
    /// final swap is a same-volume rename.
    let stagedApp: URL
    let workDirectory: URL
    let version: ReleaseVersion
}

enum UpdateError: LocalizedError, Equatable {
    case notInstalledAsApp
    case locationNotWritable(String)
    case downloadFailed(String)
    case tooLarge
    case checksumMissing
    case checksumMismatch
    case mountFailed
    case appNotFound
    case signatureInvalid
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .notInstalledAsApp:
            "Updates can only be installed into the packaged app."
        case let .locationNotWritable(folder):
            "Zulip Mac cannot replace itself in “\(folder)”. Move it to Applications or open the release page to install manually."
        case let .downloadFailed(reason):
            "The update could not be downloaded: \(reason)"
        case .tooLarge:
            "The update download is unexpectedly large and was discarded."
        case .checksumMissing:
            "The release has no usable SHA-256 checksum."
        case .checksumMismatch:
            "The downloaded update did not match its SHA-256 checksum and was discarded."
        case .mountFailed:
            "The downloaded disk image could not be opened."
        case .appNotFound:
            "The disk image does not contain Zulip Mac."
        case .signatureInvalid:
            "The downloaded app failed its signature check and was discarded."
        case .identityMismatch:
            "The downloaded app is not the expected Zulip Mac release and was discarded."
        }
    }
}

protocol UpdateInstalling: Sendable {
    func prepare(_ release: AvailableRelease, replacing appURL: URL) async throws -> PreparedUpdate
    /// Hands off to a helper that swaps the bundle once this process exits.
    @MainActor func relaunch(with update: PreparedUpdate, replacing appURL: URL) throws
}

struct SystemUpdateInstaller: UpdateInstalling {
    static let maximumDownloadBytes: Int64 = 300 * 1024 * 1024

    func prepare(_ release: AvailableRelease, replacing appURL: URL) async throws -> PreparedUpdate {
        guard appURL.pathExtension == "app" else {
            throw UpdateError.notInstalledAsApp
        }
        let parent = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.locationNotWritable(parent.lastPathComponent)
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZulipMacUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        do {
            return try await stage(release, appURL: appURL, workDirectory: workDirectory)
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            throw error
        }
    }

    private func stage(
        _ release: AvailableRelease,
        appURL: URL,
        workDirectory: URL
    ) async throws -> PreparedUpdate {
        let dmgURL = workDirectory.appendingPathComponent(release.dmgName)
        try await download(release.dmgURL, to: dmgURL)

        let checksumText = try await text(from: release.checksumURL)
        guard let expected = ReleaseFeed.checksum(from: checksumText, expectedName: release.dmgName) else {
            throw UpdateError.checksumMissing
        }
        guard try Self.sha256(of: dmgURL) == expected else {
            throw UpdateError.checksumMismatch
        }

        let mountPoint = workDirectory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let attach = try await Self.run(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, dmgURL.path]
        )
        guard attach == 0 else {
            throw UpdateError.mountFailed
        }

        let staged = appURL.deletingLastPathComponent()
            .appendingPathComponent(".ZulipMac-update-\(release.version).app", isDirectory: true)
        let result: Result<Void, Error>
        do {
            try await copyAndVerify(
                from: mountPoint.appendingPathComponent("Zulip Mac.app"),
                to: staged,
                expecting: release.version
            )
            result = .success(())
        } catch {
            result = .failure(error)
        }
        _ = try? await Self.run("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path])
        if case let .failure(error) = result {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return PreparedUpdate(stagedApp: staged, workDirectory: workDirectory, version: release.version)
    }

    private func copyAndVerify(from source: URL, to staged: URL, expecting version: ReleaseVersion) async throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw UpdateError.appNotFound
        }
        try? FileManager.default.removeItem(at: staged)
        guard try await Self.run("/usr/bin/ditto", [source.path, staged.path]) == 0 else {
            throw UpdateError.downloadFailed("could not copy the app")
        }
        _ = try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        guard try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path]) == 0 else {
            throw UpdateError.signatureInvalid
        }
        guard let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == AppIdentity.bundleIdentifier,
              let tag = info[AppIdentity.releaseTagKey] as? String,
              ReleaseVersion(tag) == version
        else {
            throw UpdateError.identityMismatch
        }
    }

    @MainActor
    func relaunch(with update: PreparedUpdate, replacing appURL: URL) throws {
        let script = update.workDirectory.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/sh
        pid="$1"; app="$2"; staged="$3"; backup="$4"; work="$5"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        if mv "$app" "$backup"; then
          if mv "$staged" "$app"; then
            rm -rf "$backup"
          else
            mv "$backup" "$app"
          fi
        fi
        open "$app"
        rm -rf "$work"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let backup = appURL.deletingLastPathComponent()
            .appendingPathComponent(".ZulipMac-previous-\(ProcessInfo.processInfo.processIdentifier).app")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            appURL.path,
            update.stagedApp.path,
            backup.path,
            update.workDirectory.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    private func download(_ url: URL, to destination: URL) async throws {
        do {
            let (temporary, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw UpdateError.downloadFailed("HTTP \(http.statusCode)")
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= Self.maximumDownloadBytes else {
                try? FileManager.default.removeItem(at: temporary)
                throw UpdateError.tooLarge
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
    }

    private func text(from url: URL) async throws -> String {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw UpdateError.downloadFailed("HTTP \(http.statusCode)")
            }
            guard data.count < 4_096 else {
                throw UpdateError.checksumMissing
            }
            return String(decoding: data, as: UTF8.self)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a system tool off the main actor and returns its exit status.
    static func run(_ executable: String, _ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
