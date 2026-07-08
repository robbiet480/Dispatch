import DispatchKit
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

/// NotificationPrefs backed by the same isolated suite as ThemeStore/
/// AwakeStore — extended the same way so settings UI (Plan 4 Task 3) and
/// UI tests read/write the same isolated defaults as the rest of the app.
private struct NotificationPrefsKey: EnvironmentKey {
    static let defaultValue = NotificationPrefs(defaults: .standard)
}

extension EnvironmentValues {
    var notificationPrefs: NotificationPrefs {
        get { self[NotificationPrefsKey.self] }
        set { self[NotificationPrefsKey.self] = newValue }
    }
}
