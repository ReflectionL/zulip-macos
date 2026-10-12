import Foundation
import Observation

protocol ReleaseFetching: Sendable {
    func newestRelease() async throws -> AvailableRelease?
}

struct GitHubReleaseFetcher: ReleaseFetching {
    /// Reads the public releases feed first because the REST API allows only 60
    /// anonymous requests per hour per address, which shared networks exhaust.
    func newestRelease() async throws -> AvailableRelease? {
        if let data = try? await fetch(
            "https://github.com/\(AppIdentity.releaseRepository)/releases.atom",
            accept: "application/atom+xml"
        ),
            let release = try? ReleaseFeed.newest(
                fromAtom: data,
                repository: AppIdentity.releaseRepository
            )
        {
            return release
        }
        let data = try await fetch(
            "https://api.github.com/repos/\(AppIdentity.releaseRepository)/releases?per_page=30",
            accept: "application/vnd.github+json"
        )
        return try ReleaseFeed.newest(from: data)
    }

    private func fetch(_ address: String, accept: String) async throws -> Data {
        guard let url = URL(string: address) else {
            throw ReleaseFeedError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("ZulipMac-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            // A bare 403 can be a block rather than a quota, so only report a rate
            // limit when GitHub says the quota is spent or asks us to back off.
            let quotaSpent = http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
                || http.value(forHTTPHeaderField: "retry-after") != nil
            if http.statusCode == 429 || (http.statusCode == 403 && quotaSpent) {
                throw ReleaseFeedError.rateLimited
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw ReleaseFeedError.http(http.statusCode)
            }
        }
        return data
    }
}

/// Checks GitHub for a newer release and installs it in place.
@MainActor
@Observable
final class UpdateController {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableRelease)
        case downloading(AvailableRelease)
        case failed(String)
    }

    static let automaticCheckInterval: TimeInterval = 6 * 60 * 60
    private static let lastCheckKey = "updates.lastCheck"

    private(set) var state: State = .idle

    let installedVersion: ReleaseVersion?
    let appURL: URL

    private let fetcher: any ReleaseFetching
    private let installer: any UpdateInstalling
    private let defaults: UserDefaults
    private let now: () -> Date

    init(
        installedVersion: ReleaseVersion? = AppIdentity.installedVersion,
        appURL: URL = Bundle.main.bundleURL,
        fetcher: any ReleaseFetching = GitHubReleaseFetcher(),
        installer: any UpdateInstalling = SystemUpdateInstaller(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.installedVersion = installedVersion
        self.appURL = appURL
        self.fetcher = fetcher
        self.installer = installer
        self.defaults = defaults
        self.now = now
    }

    /// Only a packaged `.app` that knows its own release can replace itself.
    var canInstall: Bool {
        appURL.pathExtension == "app" && installedVersion != nil
    }

    var availableRelease: AvailableRelease? {
        switch state {
        case let .available(release), let .downloading(release):
            release
        default:
            nil
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading:
            true
        default:
            false
        }
    }

    /// Quiet launch-time check: at most every few hours, never surfaces errors.
    func checkAutomatically() async {
        guard canInstall, !isBusy else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date
        if let last, now().timeIntervalSince(last) < Self.automaticCheckInterval {
            return
        }
        await check(silently: true)
    }

    func checkForUpdates() async {
        guard !isBusy else { return }
        await check(silently: false)
    }

    private func check(silently: Bool) async {
        state = .checking
        // Count the attempt, not just successes, so a failing network is not retried
        // on every launch and every new window.
        defaults.set(now(), forKey: Self.lastCheckKey)
        do {
            let newest = try await fetcher.newestRelease()
            if let newest, newest.version > (installedVersion ?? ReleaseVersion("0.0.0")!) {
                state = .available(newest)
            } else {
                state = .upToDate
            }
        } catch {
            state = silently ? .idle : .failed(Self.message(for: error))
        }
    }

    func installUpdate() async {
        guard case let .available(release) = state else { return }
        guard canInstall else {
            state = .failed(UpdateError.notInstalledAsApp.localizedDescription)
            return
        }
        state = .downloading(release)
        do {
            let prepared = try await installer.prepare(release, replacing: appURL)
            try installer.relaunch(with: prepared, replacing: appURL)
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        if let feedError = error as? ReleaseFeedError {
            switch feedError {
            case .rateLimited:
                return "GitHub is limiting requests from this network right now. Try again later, or download the latest version from the releases page."
            case let .http(status):
                return "GitHub answered with HTTP \(status)."
            case .invalidResponse:
                return "GitHub returned a release list this version does not understand."
            }
        }
        if let updateError = error as? UpdateError {
            return updateError.localizedDescription
        }
        return (error as NSError).localizedDescription
    }
}
