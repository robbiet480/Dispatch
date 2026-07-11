import AppIntents
import DispatchKit
import Foundation
import os
import UIKit
import WidgetKit

private let intentLog = Logger(subsystem: "io.robbie.Dispatch", category: "app-intents")

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

/// Opens the app into a new report, optionally scoped to a prompt group —
/// the first-class Shortcuts/Siri version of tapping REPORT on Home (trigger
/// `.intent` distinguishes it in report history). Report-centric: this starts
/// a real report flow, it never files a bare answer. (Evolved from the former
/// `StartReportIntent` by adding the group parameter.)
struct FileReportIntent: AppIntent {
    static let title: LocalizedStringResource = "File Report"
    static let description = IntentDescription("Opens Dispatch and starts a new report.")
    static let openAppWhenRun = true

    @Parameter(title: "Prompt Group",
               description: "Limit the report to one prompt group's questions. Leave empty for your usual report.")
    var group: PromptGroupEntity?

    init() {}

    init(group: PromptGroupEntity? = nil) {
        self.group = group
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppActions.shared.surveyPresenter?.request = SurveyRequest(
            kind: .regular, trigger: .intent, promptGroupID: group?.id
        )
        return .result()
    }
}

/// Files a REAL report containing a single answer to a chosen question,
/// without opening the app — the user-visible, parameterized promotion of the
/// widget quick-answer machinery ("log 2 coffees"). Report-centric: the answer
/// only exists inside the report this creates.
///
/// EXECUTION: like `QuickAnswerIntent`, `perform()` runs OUTSIDE the app
/// process, so it opens the shared App Group store writable, records the
/// nag-cancel marker the app drains at next foreground, enqueues the webhook,
/// and reloads widgets. Sensor capture is out of budget here (the
/// `QuickAnswerFiler` constraint) — the report carries provenance but no live
/// sensors; users who want sensors open the app via `FileReportIntent`.
struct LogAnswerIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Answer"
    static let description = IntentDescription(
        "Files a report with your answer to a question — e.g. log 2 coffees."
    )

    @Parameter(title: "Question")
    var question: QuestionEntity

    @Parameter(title: "Value",
               description: "The answer to record (a number, Yes/No, a choice, names, or free text).")
    var value: String

    init() {}

    init(question: QuestionEntity, value: String) {
        self.question = question
        self.value = value
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Provenance (plan 19): this runs outside the app process, where the
        // launch-time injection never ran — inject before filing so intent-
        // filed reports carry the same provenance as in-app ones.
        DeviceIdentity.deviceName = await UIDevice.current.name

        guard let context = IntentStore.writableContext() else {
            return .result(dialog: "Dispatch isn't ready yet.")
        }
        do {
            guard let report = try IntentAnswerFiler.file(
                questionID: question.id, raw: value, trigger: .intent, in: context
            ) else {
                return .result(dialog: "Couldn't find that question in Dispatch.")
            }
            if let defaults = UserDefaults(suiteName: StoreLocation.appGroupID) {
                // Cancel the question's nag chain at the app's next foreground
                // (the shared widget marker path) and queue webhook delivery.
                WidgetQuickAnswerMarker.recordFiled(at: Date(), in: defaults)
                WebhookQueue.enqueue(reportID: report.uniqueIdentifier, in: defaults)
            }
            WidgetCenter.shared.reloadAllTimelines()
            let answered = report.responses?.first.flatMap(AnswerSummary.text) ?? value
            intentLog.info("logged intent answer to \(question.id, privacy: .public)")
            return .result(dialog: "Logged \(answered) to \(question.prompt).")
        } catch {
            intentLog.error("log answer failed: \(error, privacy: .public)")
            return .result(dialog: "Couldn't file that answer.")
        }
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

// MARK: - Query intents (read-only, side-effect-free)

/// How many non-draft reports were filed during the current local day.
struct TodayReportCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's Report Count"
    static let description = IntentDescription("How many reports you've filed today.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count = WidgetSnapshot.compute(reports: IntentStore.allReports()).todayCount
        let noun = count == 1 ? "report" : "reports"
        return .result(value: count, dialog: "You've filed \(count) \(noun) today.")
    }
}

/// The current consecutive-day report streak.
struct CurrentStreakIntent: AppIntent {
    static let title: LocalizedStringResource = "Current Streak"
    static let description = IntentDescription("Your consecutive-day report streak.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let streak = ReportStreak.days(reports: IntentStore.allReports(),
                                       now: Date(), calendar: .current)
        let noun = streak == 1 ? "day" : "days"
        return .result(value: streak, dialog: "Your streak is \(streak) \(noun).")
    }
}

/// The most recent answer to a chosen question, for use in Shortcuts logic.
struct LastAnswerIntent: AppIntent {
    static let title: LocalizedStringResource = "Last Answer"
    static let description = IntentDescription("Your most recent answer to a question.")

    @Parameter(title: "Question")
    var question: QuestionEntity

    init() {}

    init(question: QuestionEntity) {
        self.question = question
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String?> & ProvidesDialog {
        guard let last = AnswerSummary.lastAnswer(toQuestionID: question.id,
                                                  in: IntentStore.allReports()) else {
            return .result(value: nil, dialog: "No answer yet for \(question.prompt).")
        }
        return .result(value: last.text, dialog: "\(question.prompt): \(last.text).")
    }
}

struct DispatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FileReportIntent(),
            phrases: [
                "File a \(.applicationName) report",
                "New \(.applicationName) report",
                "Start a \(.applicationName) report",
            ],
            shortTitle: "File Report",
            systemImageName: "hexagon.fill"
        )
        AppShortcut(
            intent: LogAnswerIntent(),
            phrases: [
                "Log a \(.applicationName) answer",
                "Log an answer in \(.applicationName)",
            ],
            shortTitle: "Log Answer",
            systemImageName: "square.and.pencil"
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
        AppShortcut(
            intent: TodayReportCountIntent(),
            phrases: [
                "How many \(.applicationName) reports today",
                "Today's \(.applicationName) report count",
            ],
            shortTitle: "Today's Reports",
            systemImageName: "number"
        )
        AppShortcut(
            intent: CurrentStreakIntent(),
            phrases: [
                "What's my \(.applicationName) streak",
                "My \(.applicationName) streak",
            ],
            shortTitle: "Current Streak",
            systemImageName: "flame.fill"
        )
        AppShortcut(
            intent: LastAnswerIntent(),
            phrases: [
                "My last \(.applicationName) answer",
                "Last answer in \(.applicationName)",
            ],
            shortTitle: "Last Answer",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
