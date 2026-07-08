import Foundation
import Observation

public enum Theme: String, Codable, CaseIterable, Sendable {
    case tomato, teal, gray, pink, chartreuse

    public var backgroundHex: String {
        switch self {
        case .tomato: "#FA5B3D"
        case .teal: "#20BEC6"
        case .gray: "#9B9B9B"
        case .pink: "#F268F1"
        case .chartreuse: "#CBD82B"
        }
    }

    public var displayName: String { rawValue.capitalized }
}

@Observable
public final class ThemeStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private var _theme: Theme

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self._theme = defaults.string(forKey: "interface.theme").flatMap(Theme.init(rawValue:)) ?? .tomato
    }

    public var theme: Theme {
        get { _theme }
        set {
            _theme = newValue
            defaults.set(newValue.rawValue, forKey: "interface.theme")
        }
    }
}
