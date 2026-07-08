import AppIntents
import DispatchKit
import Foundation

/// App Intents are instantiated by the system (Shortcuts, Siri, Spotlight),
/// never by our own view hierarchy, so they can't receive `@Environment`
/// objects the way SwiftUI views do. `AppActions` is the bridge: DispatchApp
/// registers its live `SurveyPresenter` / `AwakeStore` / `NotificationScheduler`
/// / `NotificationPrefs` into this `@MainActor` singleton at launch, and
/// intents call through it instead of holding their own state.
@MainActor
final class AppActions {
    static let shared = AppActions()

    private(set) var surveyPresenter: SurveyPresenter?
    private(set) var awakeStore: AwakeStore?
    private(set) var notificationScheduler: NotificationScheduler?
    private(set) var notificationPrefs: NotificationPrefs?

    private init() {}

    func register(
        surveyPresenter: SurveyPresenter,
        awakeStore: AwakeStore,
        notificationScheduler: NotificationScheduler,
        notificationPrefs: NotificationPrefs
    ) {
        self.surveyPresenter = surveyPresenter
        self.awakeStore = awakeStore
        self.notificationScheduler = notificationScheduler
        self.notificationPrefs = notificationPrefs
    }
}

/// Opens the app straight into a new regular survey, same as tapping the
/// REPORT button on the home screen — trigger `.intent` distinguishes it
/// from a manual tap or a notification tap in report history.
struct StartReportIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Report"
    static let description = IntentDescription("Opens Dispatch and starts a new report.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppActions.shared.surveyPresenter?.request = SurveyRequest(kind: .regular, trigger: .intent)
        return .result()
    }
}

/// Flips the manual AWAKE/ASLEEP state without opening the app, re-plans
/// notifications so the schedule reflects the new state, and reports back
/// which way it flipped via a spoken/displayed dialog.
struct ToggleAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Awake/Asleep"
    static let description = IntentDescription("Toggles Dispatch's awake/asleep state.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let awakeStore = AppActions.shared.awakeStore else {
            return .result(dialog: "Dispatch isn't ready yet.")
        }
        awakeStore.toggle()
        if let scheduler = AppActions.shared.notificationScheduler,
           let prefs = AppActions.shared.notificationPrefs {
            scheduler.replan(prefs: prefs, awakeStore: awakeStore)
        }
        let dialog: IntentDialog = awakeStore.isAwake ? "You're now awake" : "You're now asleep"
        return .result(dialog: dialog)
    }
}

struct DispatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartReportIntent(),
            phrases: [
                "Start a \(.applicationName) report",
                "New \(.applicationName) report",
            ],
            shortTitle: "Start Report",
            systemImageName: "hexagon.fill"
        )
        AppShortcut(
            intent: ToggleAwakeIntent(),
            phrases: [
                "Toggle \(.applicationName) awake",
                "Toggle my \(.applicationName) status",
            ],
            shortTitle: "Toggle Awake",
            systemImageName: "moon.zzz.fill"
        )
    }
}
