import Foundation

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

public final class ThemeStore: @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var theme: Theme {
        get { defaults.string(forKey: "interface.theme").flatMap(Theme.init(rawValue:)) ?? .tomato }
        set { defaults.set(newValue.rawValue, forKey: "interface.theme") }
    }
}
