import Foundation

/// A semantic version such as `0.1.0-alpha.2`, parsed from a release tag.
struct ReleaseVersion: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") {
            text.removeFirst()
        }
        let halves = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = halves.first else { return nil }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
              let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2]),
              major >= 0, minor >= 0, patch >= 0
        else {
            return nil
        }
        var identifiers: [String] = []
        if halves.count == 2 {
            identifiers = halves[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = identifiers
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // A release without a suffix is newer than any prerelease of the same core.
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (leftNumber?, rightNumber?):
                return leftNumber < rightNumber
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// A downloadable release as published by the GitHub Releases API.
struct AvailableRelease: Equatable, Sendable {
    let version: ReleaseVersion
    let tag: String
    let notes: String
    let pageURL: URL?
    let dmgURL: URL
    let checksumURL: URL
    let dmgName: String
}

enum ReleaseFeedError: Error, Equatable, Sendable {
    case invalidResponse
    case http(Int)
    case rateLimited
}

/// Decodes the GitHub Releases list and picks the newest installable release.
enum ReleaseFeed {
    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let draft: Bool
        let body: String?
        let htmlURL: URL?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft
            case body
            case htmlURL = "html_url"
            case assets
        }
    }

    static func newest(from data: Data) throws -> AvailableRelease? {
        let payloads: [Payload]
        do {
            payloads = try JSONDecoder().decode([Payload].self, from: data)
        } catch {
            throw ReleaseFeedError.invalidResponse
        }
        return payloads
            .compactMap(release(from:))
            .max { $0.version < $1.version }
    }

    /// Reads the public `releases.atom` feed, which is not subject to the
    /// unauthenticated REST API limit, and derives each release's asset URLs from
    /// the naming scheme `package-dmg.sh` uses.
    static func newest(fromAtom data: Data, repository: String) throws -> AvailableRelease? {
        let collector = AtomTagCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else {
            throw ReleaseFeedError.invalidResponse
        }
        return collector.tags
            .compactMap { release(tag: $0, repository: repository) }
            .max { $0.version < $1.version }
    }

    private static func release(tag: String, repository: String) -> AvailableRelease? {
        guard tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }),
              let version = ReleaseVersion(tag)
        else {
            return nil
        }
        let base = "https://github.com/\(repository)/releases"
        let name = "Zulip-Mac-\(version)-arm64.dmg"
        guard let dmgURL = URL(string: "\(base)/download/\(tag)/\(name)"),
              let checksumURL = URL(string: "\(base)/download/\(tag)/\(name).sha256"),
              isTrustedDownload(dmgURL),
              isTrustedDownload(checksumURL)
        else {
            return nil
        }
        return AvailableRelease(
            version: version,
            tag: tag,
            notes: "",
            pageURL: URL(string: "\(base)/tag/\(tag)"),
            dmgURL: dmgURL,
            checksumURL: checksumURL,
            dmgName: name
        )
    }

    private static func release(from payload: Payload) -> AvailableRelease? {
        guard !payload.draft, let version = ReleaseVersion(payload.tagName) else {
            return nil
        }
        guard let dmg = payload.assets.first(where: {
            $0.name.hasPrefix("Zulip-Mac-") && $0.name.hasSuffix("-arm64.dmg")
        }),
            let checksum = payload.assets.first(where: { $0.name == dmg.name + ".sha256" }),
            isTrustedDownload(dmg.browserDownloadURL),
            isTrustedDownload(checksum.browserDownloadURL)
        else {
            return nil
        }
        return AvailableRelease(
            version: version,
            tag: payload.tagName,
            notes: payload.body ?? "",
            pageURL: payload.htmlURL,
            dmgURL: dmg.browserDownloadURL,
            checksumURL: checksum.browserDownloadURL,
            dmgName: dmg.name
        )
    }

    /// Release assets are only fetched over HTTPS from GitHub.
    static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else {
            return false
        }
        return host == "github.com" || host.hasSuffix(".github.com")
            || host.hasSuffix(".githubusercontent.com")
    }

    /// Reads `<hex digest>  <file name>` as written by `package-dmg.sh`.
    static func checksum(from text: String, expectedName: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let digest = parts[0].lowercased()
            let name = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if name == expectedName, digest.count == 64, digest.allSatisfy(\.isHexDigit) {
                return digest
            }
        }
        return nil
    }
}

/// Collects the tag of every `<entry>` in a GitHub releases Atom feed.
private final class AtomTagCollector: NSObject, XMLParserDelegate {
    private(set) var tags: [String] = []
    private var insideEntry = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "entry" {
            insideEntry = true
        } else if insideEntry, elementName == "link",
                  attributeDict["rel"] == nil || attributeDict["rel"] == "alternate",
                  let href = attributeDict["href"],
                  let range = href.range(of: "/releases/tag/")
        {
            let tag = String(href[range.upperBound...])
            tags.append(tag.removingPercentEncoding ?? tag)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "entry" {
            insideEntry = false
        }
    }
}
