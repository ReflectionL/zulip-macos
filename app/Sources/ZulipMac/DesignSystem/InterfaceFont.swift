import AppKit
import Foundation
import Observation

/// The user's choice of interface typeface, remembered across launches. `nil`
/// means the system font. `AppTheme.Typography` builds its proportional fonts
/// from `family`, and because views read it while building their body, a change
/// redraws the whole interface. Code and math keep their own faces.
@MainActor
@Observable
final class InterfaceFont {
    static let shared = InterfaceFont()

    private static let defaultsKey = "interfaceFontFamily"

    private(set) var family: String?
    private let defaults: UserDefaults
    private let isInstalled: (String) -> Bool

    init(
        defaults: UserDefaults = .standard,
        isInstalled: @escaping (String) -> Bool = InterfaceFont.systemHasFamily
    ) {
        self.defaults = defaults
        self.isInstalled = isInstalled
        // A font that has since been uninstalled falls back to the system font
        // without forgetting the choice, so it returns if the font does.
        family = defaults.string(forKey: Self.defaultsKey).flatMap {
            $0.isEmpty || !isInstalled($0) ? nil : $0
        }
    }

    /// Chooses `value`, or the system font for `nil`.
    func select(_ value: String?) {
        guard value != family else {
            return
        }
        family = value
        if let value {
            defaults.set(value, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    /// The font families installed on this Mac, sorted for display.
    nonisolated static func installedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated static func systemHasFamily(_ family: String) -> Bool {
        NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
    }
}
