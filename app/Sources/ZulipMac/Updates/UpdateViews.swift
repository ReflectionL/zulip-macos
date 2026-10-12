import SwiftUI

struct UpdateSettingsSection: View {
    let updates: UpdateController

    var body: some View {
        Section("Updates") {
            LabeledContent("Installed version") {
                Text(updates.installedVersion.map { "v\($0)" } ?? "Development build")
            }

            switch updates.state {
            case .idle:
                EmptyView()
            case .checking:
                statusRow("Checking for updates…", showsProgress: true)
            case .upToDate:
                statusRow("Zulip Mac is up to date.")
            case let .available(release):
                availableRows(release, isDownloading: false)
            case let .downloading(release):
                availableRows(release, isDownloading: true)
            case let .failed(message):
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Check for Updates") {
                    Task { await updates.checkForUpdates() }
                }
                .disabled(updates.isBusy)
                if !updates.canInstall {
                    Text("Updates install only in the packaged app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusRow(_ text: String, showsProgress: Bool = false) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small)
            }
            Text(text).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func availableRows(_ release: AvailableRelease, isDownloading: Bool) -> some View {
        LabeledContent("Latest version", value: "v\(release.version)")
        if isDownloading {
            statusRow("Downloading and verifying v\(release.version)…", showsProgress: true)
        } else {
            HStack {
                Button("Install and Restart") {
                    Task { await updates.installUpdate() }
                }
                .disabled(!updates.canInstall)
                if let page = release.pageURL {
                    Link("Release notes", destination: page)
                }
            }
        }
    }
}

struct UpdateCommands: Commands {
    let updates: UpdateController
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                openSettings()
                Task { await updates.checkForUpdates() }
            }
        }
    }
}
