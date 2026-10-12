import Foundation
import Observation

/// The user's text-size preference. Every font in `AppTheme.Typography` multiplies
/// its size by `factor`, and because views read it while building their body, a
/// change redraws the whole interface.
@MainActor
@Observable
final class InterfaceScale {
    static let shared = InterfaceScale()

    /// The sizes the zoom commands step through; `1` is the standard size.
    nonisolated static let steps: [Double] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.4, 1.6, 1.8, 2.0]
    nonisolated static let standardIndex = 2

    private static let defaultsKey = "interfaceScale"

    private(set) var factor: Double
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.defaultsKey)
        factor = Self.steps[Self.nearestIndex(to: stored > 0 ? stored : 1)]
    }

    var canIncrease: Bool {
        Self.nearestIndex(to: factor) < Self.steps.count - 1
    }

    var canDecrease: Bool {
        Self.nearestIndex(to: factor) > 0
    }

    var isStandard: Bool {
        Self.nearestIndex(to: factor) == Self.standardIndex
    }

    func increase() {
        move(by: 1)
    }

    func decrease() {
        move(by: -1)
    }

    func reset() {
        apply(Self.steps[Self.standardIndex])
    }

    private func move(by delta: Int) {
        let next = min(max(Self.nearestIndex(to: factor) + delta, 0), Self.steps.count - 1)
        apply(Self.steps[next])
    }

    private func apply(_ value: Double) {
        guard value != factor else {
            return
        }
        factor = value
        defaults.set(value, forKey: Self.defaultsKey)
    }

    nonisolated static func nearestIndex(to value: Double) -> Int {
        var best = standardIndex
        var distance = Double.infinity
        for (index, step) in steps.enumerated() where abs(step - value) < distance {
            best = index
            distance = abs(step - value)
        }
        return best
    }
}
