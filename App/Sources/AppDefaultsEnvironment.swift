import SwiftUI

/// The active UserDefaults suite — `.standard` normally, or an isolated
/// "ui-testing" suite (wiped at launch) when running under
/// --mock-sensors / --ui-testing, so UI tests never leak state into or
/// out of the real app's defaults.
private struct AppDefaultsKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: UserDefaults = .standard
}

extension EnvironmentValues {
    var appDefaults: UserDefaults {
        get { self[AppDefaultsKey.self] }
        set { self[AppDefaultsKey.self] = newValue }
    }
}
