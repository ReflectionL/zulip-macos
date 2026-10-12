import Foundation

enum AppIdentity {
    static let displayName = "Zulip Mac"
    static let bundleIdentifier = "io.github.huahai.ZulipMac"
    static let minimumSystem = "macOS 26"
    static let releaseTagKey = "ZulipReleaseTag"
    static let releaseRepository = "ReflectionL/zulip-macos"

    /// The release this build was packaged from, or nil for unpackaged builds.
    static var installedVersion: ReleaseVersion? {
        (Bundle.main.object(forInfoDictionaryKey: releaseTagKey) as? String)
            .flatMap(ReleaseVersion.init)
    }
}
