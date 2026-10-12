import Foundation
import Testing
@testable import ZulipMac

@Suite("Updates")
@MainActor
struct UpdateTests {
    private func version(_ text: String) -> ReleaseVersion {
        guard let version = ReleaseVersion(text) else {
            Issue.record("unparseable version \(text)")
            return ReleaseVersion("0.0.0")!
        }
        return version
    }

    @Test("Versions parse with or without a leading v and reject malformed tags")
    func parsing() {
        #expect(ReleaseVersion("v0.1.0-alpha.2")?.description == "0.1.0-alpha.2")
        #expect(ReleaseVersion("1.2.3")?.prerelease.isEmpty == true)
        #expect(ReleaseVersion("1.2") == nil)
        #expect(ReleaseVersion("1.2.x") == nil)
        #expect(ReleaseVersion("1.2.3-") == nil)
        #expect(ReleaseVersion("") == nil)
    }

    @Test("Versions order by core, then stable above prerelease, then identifiers")
    func ordering() {
        #expect(version("0.1.0-alpha.1") < version("0.1.0-alpha.2"))
        #expect(version("0.1.0-alpha.2") < version("0.1.0-alpha.10"))
        #expect(version("0.1.0-alpha.2") < version("0.1.0-beta.1"))
        #expect(version("0.1.0-rc.1") < version("0.1.0"))
        #expect(version("0.1.0") < version("0.1.1-alpha.1"))
        #expect(version("0.9.0") < version("0.10.0"))
        #expect(version("1.0.0-alpha") < version("1.0.0-alpha.1"))
        #expect(!(version("0.1.0") < version("0.1.0")))
    }

    private func releaseJSON(
        tag: String,
        draft: Bool = false,
        dmgHost: String = "github.com",
        includeChecksum: Bool = true
    ) -> String {
        let name = "Zulip-Mac-\(tag.dropFirst())-arm64.dmg"
        var assets = """
        {"name":"\(name)","browser_download_url":"https://\(dmgHost)/ReflectionL/zulip-macos/releases/download/\(tag)/\(name)"}
        """
        if includeChecksum {
            assets += """
            ,{"name":"\(name).sha256","browser_download_url":"https://github.com/ReflectionL/zulip-macos/releases/download/\(tag)/\(name).sha256"}
            """
        }
        return """
        {"tag_name":"\(tag)","draft":\(draft),"body":"notes","html_url":"https://github.com/ReflectionL/zulip-macos/releases/tag/\(tag)","assets":[\(assets)]}
        """
    }

    private func feed(_ entries: [String]) -> Data {
        Data("[\(entries.joined(separator: ","))]".utf8)
    }

    @Test("The newest installable release wins regardless of list order")
    func newestRelease() throws {
        let data = feed([
            releaseJSON(tag: "v0.1.0-alpha.2"),
            releaseJSON(tag: "v0.1.0-alpha.10"),
            releaseJSON(tag: "v0.1.0-alpha.9"),
        ])
        let release = try #require(try ReleaseFeed.newest(from: data))
        #expect(release.tag == "v0.1.0-alpha.10")
        #expect(release.dmgName == "Zulip-Mac-0.1.0-alpha.10-arm64.dmg")
        #expect(release.notes == "notes")
    }

    @Test("Drafts, missing checksums and untrusted hosts are not offered")
    func skipsUnusableReleases() throws {
        let data = feed([
            releaseJSON(tag: "v0.3.0", draft: true),
            releaseJSON(tag: "v0.2.0", includeChecksum: false),
            releaseJSON(tag: "v0.2.5", dmgHost: "evil.example.com"),
            releaseJSON(tag: "v0.1.0-alpha.2"),
        ])
        #expect(try ReleaseFeed.newest(from: data)?.tag == "v0.1.0-alpha.2")
        #expect(try ReleaseFeed.newest(from: feed([])) == nil)
    }

    @Test("The public Atom feed yields the newest release with derived download URLs")
    func atomFeed() throws {
        func entry(_ tag: String) -> String {
            """
            <entry>
              <id>tag:github.com,2008:Repository/1/\(tag)</id>
              <link rel="alternate" type="text/html" href="https://github.com/ReflectionL/zulip-macos/releases/tag/\(tag)"/>
              <title>Zulip Mac \(tag)</title>
            </entry>
            """
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <id>tag:github.com,2008:https://github.com/ReflectionL/zulip-macos/releases</id>
          <link type="text/html" rel="alternate" href="https://github.com/ReflectionL/zulip-macos/releases"/>
          \(entry("v0.1.0-alpha.3"))
          \(entry("v0.1.0-alpha.4"))
          \(entry("not-a-version"))
        </feed>
        """
        let release = try #require(
            try ReleaseFeed.newest(fromAtom: Data(xml.utf8), repository: "ReflectionL/zulip-macos")
        )
        #expect(release.tag == "v0.1.0-alpha.4")
        #expect(release.version == version("0.1.0-alpha.4"))
        #expect(release.dmgName == "Zulip-Mac-0.1.0-alpha.4-arm64.dmg")
        #expect(
            release.dmgURL.absoluteString
                == "https://github.com/ReflectionL/zulip-macos/releases/download/v0.1.0-alpha.4/Zulip-Mac-0.1.0-alpha.4-arm64.dmg"
        )
        #expect(release.checksumURL.absoluteString == release.dmgURL.absoluteString + ".sha256")
        #expect(
            try ReleaseFeed.newest(fromAtom: Data("<feed/>".utf8), repository: "a/b") == nil
        )
        #expect(throws: ReleaseFeedError.self) {
            try ReleaseFeed.newest(fromAtom: Data("not xml".utf8), repository: "a/b")
        }
    }

    @Test("A malformed feed is reported rather than ignored")
    func malformedFeed() {
        #expect(throws: ReleaseFeedError.invalidResponse) {
            try ReleaseFeed.newest(from: Data("{}".utf8))
        }
    }

    @Test("Only HTTPS GitHub hosts are trusted download sources")
    func trustedHosts() throws {
        #expect(ReleaseFeed.isTrustedDownload(try #require(URL(string: "https://github.com/a/b"))))
        #expect(ReleaseFeed.isTrustedDownload(
            try #require(URL(string: "https://objects.githubusercontent.com/x"))
        ))
        #expect(!ReleaseFeed.isTrustedDownload(try #require(URL(string: "http://github.com/a"))))
        #expect(!ReleaseFeed.isTrustedDownload(try #require(URL(string: "https://github.com.evil.io/a"))))
        #expect(!ReleaseFeed.isTrustedDownload(try #require(URL(string: "https://notgithub.com/a"))))
    }

    @Test("Checksum files are matched by file name and digest shape")
    func checksumParsing() {
        let digest = String(repeating: "ab", count: 32)
        #expect(ReleaseFeed.checksum(from: "\(digest)  App.dmg\n", expectedName: "App.dmg") == digest)
        #expect(ReleaseFeed.checksum(from: "\(digest.uppercased())  App.dmg", expectedName: "App.dmg") == digest)
        #expect(ReleaseFeed.checksum(from: "\(digest)  Other.dmg", expectedName: "App.dmg") == nil)
        #expect(ReleaseFeed.checksum(from: "short  App.dmg", expectedName: "App.dmg") == nil)
    }

    @Test("A downloaded file hashes to its SHA-256")
    func hashing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hash-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(
            try SystemUpdateInstaller.sha256(of: url)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    // MARK: - Controller

    private struct StubFetcher: ReleaseFetching {
        var result: Result<AvailableRelease?, ReleaseFeedError>

        func newestRelease() async throws -> AvailableRelease? {
            try result.get()
        }
    }

    private final class StubInstaller: UpdateInstalling, @unchecked Sendable {
        private(set) var prepared: [String] = []
        private(set) var relaunched = false
        var failure: UpdateError?

        func prepare(_ release: AvailableRelease, replacing appURL: URL) async throws -> PreparedUpdate {
            prepared.append(release.tag)
            if let failure { throw failure }
            return PreparedUpdate(
                stagedApp: appURL,
                workDirectory: appURL,
                version: release.version
            )
        }

        @MainActor
        func relaunch(with update: PreparedUpdate, replacing appURL: URL) throws {
            relaunched = true
        }
    }

    private func release(_ tag: String) -> AvailableRelease {
        AvailableRelease(
            version: version(tag),
            tag: tag,
            notes: "",
            pageURL: nil,
            dmgURL: URL(string: "https://github.com/x/y/a.dmg")!,
            checksumURL: URL(string: "https://github.com/x/y/a.dmg.sha256")!,
            dmgName: "a.dmg"
        )
    }

    private func controller(
        installed: String? = "0.1.0-alpha.3",
        fetcher: StubFetcher,
        installer: StubInstaller = StubInstaller(),
        appPath: String = "/Applications/Zulip Mac.app",
        clock: @escaping () -> Date = Date.init
    ) -> UpdateController {
        let defaults = UserDefaults(suiteName: "updates-\(UUID().uuidString)")!
        return UpdateController(
            installedVersion: installed.flatMap(ReleaseVersion.init),
            appURL: URL(fileURLWithPath: appPath),
            fetcher: fetcher,
            installer: installer,
            defaults: defaults,
            now: clock
        )
    }

    @Test("A newer release becomes available and an equal one is up to date")
    func checkOutcomes() async {
        let newer = controller(fetcher: StubFetcher(result: .success(release("v0.1.0-alpha.4"))))
        await newer.checkForUpdates()
        #expect(newer.state == .available(release("v0.1.0-alpha.4")))

        let same = controller(fetcher: StubFetcher(result: .success(release("v0.1.0-alpha.3"))))
        await same.checkForUpdates()
        #expect(same.state == .upToDate)

        let none = controller(fetcher: StubFetcher(result: .success(nil)))
        await none.checkForUpdates()
        #expect(none.state == .upToDate)
    }

    @Test("Manual checks report failures but automatic checks stay quiet")
    func failureVisibility() async {
        let failing = StubFetcher(result: .failure(.rateLimited))

        let manual = controller(fetcher: failing)
        await manual.checkForUpdates()
        if case .failed = manual.state {} else {
            Issue.record("expected a visible failure, got \(manual.state)")
        }

        let automatic = controller(fetcher: failing)
        await automatic.checkAutomatically()
        #expect(automatic.state == .idle)
    }

    @Test("Automatic checks are rate limited and skipped for unpackaged builds")
    func automaticChecks() async {
        var current = Date(timeIntervalSince1970: 1_000_000)
        let packaged = controller(
            fetcher: StubFetcher(result: .success(release("v0.1.0-alpha.4"))),
            clock: { current }
        )
        await packaged.checkAutomatically()
        #expect(packaged.availableRelease != nil)

        let stale = packaged.state
        await packaged.checkAutomatically()
        #expect(packaged.state == stale)

        current.addTimeInterval(UpdateController.automaticCheckInterval + 1)
        await packaged.checkAutomatically()
        #expect(packaged.state == stale)

        let development = controller(
            installed: nil,
            fetcher: StubFetcher(result: .success(release("v9.0.0"))),
            appPath: "/tmp/ZulipMac"
        )
        await development.checkAutomatically()
        #expect(development.state == .idle)
        #expect(!development.canInstall)
    }

    @Test("Installing prepares the release and hands off to the relauncher")
    func install() async {
        let installer = StubInstaller()
        let subject = controller(
            fetcher: StubFetcher(result: .success(release("v0.1.0-alpha.4"))),
            installer: installer
        )
        await subject.installUpdate()
        #expect(installer.prepared.isEmpty)

        await subject.checkForUpdates()
        await subject.installUpdate()
        #expect(installer.prepared == ["v0.1.0-alpha.4"])
        #expect(installer.relaunched)
    }

    @Test("A failed preparation returns to a visible error and does not relaunch")
    func installFailure() async {
        let installer = StubInstaller()
        installer.failure = .checksumMismatch
        let subject = controller(
            fetcher: StubFetcher(result: .success(release("v0.1.0-alpha.4"))),
            installer: installer
        )
        await subject.checkForUpdates()
        await subject.installUpdate()
        #expect(subject.state == .failed(UpdateError.checksumMismatch.localizedDescription))
        #expect(!installer.relaunched)
    }
}
