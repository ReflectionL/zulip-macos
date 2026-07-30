import Observation
import ZulipCoreBindings

struct NavigationDestination: Identifiable, Equatable, Sendable {
    let key: ConversationKey
    let title: String
    let subtitle: String
    let systemImage: String
    let keywords: [String]

    var id: ConversationKey { key }
}

struct NavigationDirectory: Equatable, Sendable {
    let destinations: [NavigationDestination]

    func destination(for key: ConversationKey) -> NavigationDestination? {
        destinations.first { $0.key == key }
    }

    func search(_ query: String, limit: Int = 12) -> [NavigationDestination] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !needle.isEmpty else {
            return Array(destinations.prefix(limit))
        }

        return destinations
            .compactMap { destination -> (Int, NavigationDestination)? in
                let title = destination.title.lowercased()
                let subtitle = destination.subtitle.lowercased()
                let keywords = destination.keywords.map { $0.lowercased() }

                let score: Int?
                if title == needle {
                    score = 0
                } else if title.hasPrefix(needle) {
                    score = 1
                } else if title.contains(needle) {
                    score = 2
                } else if subtitle.contains(needle) || keywords.contains(where: { $0.contains(needle) }) {
                    score = 3
                } else {
                    score = nil
                }

                return score.map { ($0, destination) }
            }
            .sorted {
                if $0.0 == $1.0 {
                    $0.1.title.localizedCaseInsensitiveCompare($1.1.title) == .orderedAscending
                } else {
                    $0.0 < $1.0
                }
            }
            .prefix(limit)
            .map(\.1)
    }
}

@MainActor
@Observable
final class NavigationStore {
    var directory: NavigationDirectory

    var selection: ConversationKey
    var isCommandPalettePresented = false
    var query = ""

    init(directory: NavigationDirectory, initialSelection: ConversationKey) {
        self.directory = directory
        selection = initialSelection
    }

    var selectedDestination: NavigationDestination? {
        directory.destination(for: selection)
    }

    var searchResults: [NavigationDestination] {
        directory.search(query)
    }

    func select(_ key: ConversationKey) {
        guard directory.destination(for: key) != nil else {
            return
        }

        selection = key
        dismissCommandPalette()
    }

    func replaceDirectory(_ directory: NavigationDirectory) {
        self.directory = directory
        if directory.destination(for: selection) == nil,
           let first = directory.destinations.first
        {
            selection = first.key
        }
    }

    func presentCommandPalette() {
        query = ""
        isCommandPalettePresented = true
    }

    func dismissCommandPalette() {
        isCommandPalettePresented = false
        query = ""
    }
}
