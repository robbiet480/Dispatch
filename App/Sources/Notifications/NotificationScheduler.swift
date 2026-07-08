import DispatchKit
import Foundation
import Observation
import os
import SwiftData
import UserNotifications

private let notificationLog = Logger(subsystem: "com.robbiet480.dispatch", category: "notifications")

/// Category + action identifiers for the interactive `DISPATCH_PROMPT`
/// notification (quick Yes/No answer + snooze) and the pending-request
/// identifier prefixes used to distinguish re-plannable prompts from
/// one-off snoozes.
enum NotificationIdentifiers {
    static let category = "DISPATCH_PROMPT"
    static let answerYesAction = "answer-yes"
    static let answerNoAction = "answer-no"
    static let snoozeAction = "snooze"
    static let promptPrefix = "prompt-"
    static let snoozePrefix = "snooze-"
}

/// Owns UNUserNotificationCenter: permission, request building/re-planning,
/// delegate routing for quick answers/snooze/tap-through, and the
/// pending-survey handoff to the app's SurveyPresenter.
///
/// Quick-answer notification actions file a MINIMAL report directly —
/// `trigger: .notification`, the single answered question, and NO sensor
/// capture. Location/health/photo/weather capture requires async work
/// (permissions, background tasks) that is out of budget for a
/// notification-action handler, which iOS expects to complete quickly.
/// Users who want a full sensor-backed report should tap the notification
/// body instead, which opens the app into a normal survey.
@MainActor
@Observable
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let container: ModelContainer
    private let isTestEnvironment: Bool

    init(container: ModelContainer, isTestEnvironment: Bool) {
        self.container = container
        self.isTestEnvironment = isTestEnvironment
        super.init()
    }

    // MARK: - Setup

    /// Registers the DISPATCH_PROMPT category with quick-answer actions
    /// drawn from the first enabled regular-kind Yes/No question (falling
    /// back to generic Yes/No titles if none exists yet) plus "Snooze 15m".
    /// Safe to call repeatedly; UNUserNotificationCenter replaces the
    /// category definition each time.
    func registerCategory() {
        let context = ModelContext(container)
        let question = Self.firstEnabledYesNoQuestion(in: context)

        let yesTitle = question?.choices.first ?? "Yes"
        let noTitle = question?.choices.count ?? 0 > 1 ? question!.choices[1] : "No"

        let yesAction = UNNotificationAction(
            identifier: NotificationIdentifiers.answerYesAction,
            title: yesTitle,
            options: []
        )
        let noAction = UNNotificationAction(
            identifier: NotificationIdentifiers.answerNoAction,
            title: noTitle,
            options: []
        )
        let snoozeAction = UNNotificationAction(
            identifier: NotificationIdentifiers.snoozeAction,
            title: "Snooze 15m",
            options: []
        )

        let category = UNNotificationCategory(
            identifier: NotificationIdentifiers.category,
            actions: [yesAction, noAction, snoozeAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Requests `.alert .sound .badge` permission. Skipped under
    /// `--mock-sensors` / `--ui-testing` so UI tests never hit the system
    /// permission dialog (which blocks the test runner indefinitely).
    func requestPermissionIfNeeded() {
        guard !isTestEnvironment else { return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                notificationLog.error("notification permission request failed: \(error, privacy: .public)")
            } else {
                notificationLog.info("notification permission granted: \(granted, privacy: .public)")
            }
        }
    }

    // MARK: - Planning

    /// Re-plans pending DISPATCH_PROMPT requests: clears everything with the
    /// `prompt-` identifier prefix (snoozes are untouched), does nothing
    /// further while asleep, otherwise plans today's remaining window plus
    /// tomorrow's full window and schedules calendar-trigger requests for
    /// every future date.
    func replan(prefs: NotificationPrefs, awakeStore: AwakeStore, now: Date = Date(), calendar: Calendar = .current) {
        removePendingPromptRequests()
        guard awakeStore.isAwake else { return }

        let dates = plannedDates(prefs: prefs, now: now, calendar: calendar)
            .filter { $0 > now }

        for (index, date) in dates.enumerated() {
            let identifier = "\(NotificationIdentifiers.promptPrefix)\(Self.isoDayFormatter.string(from: date))-\(index)"
            let content = Self.makeContent()
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            center.add(request) { error in
                if let error {
                    notificationLog.error("failed to schedule prompt \(identifier, privacy: .public): \(error, privacy: .public)")
                }
            }
        }
    }

    private func plannedDates(prefs: NotificationPrefs, now: Date, calendar: Calendar) -> [Date] {
        let todayStart = calendar.startOfDay(for: now)
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart),
              let dayAfterStart = calendar.date(byAdding: .day, value: 2, to: todayStart) else {
            return []
        }

        var awakeStartComponents = DateComponents()
        awakeStartComponents.hour = 8
        awakeStartComponents.minute = 0

        let todayAwakeStart = calendar.date(byAdding: awakeStartComponents, to: todayStart) ?? todayStart
        let todayAwakeEnd = tomorrowStart
        let tomorrowAwakeStart = calendar.date(byAdding: awakeStartComponents, to: tomorrowStart) ?? tomorrowStart
        let tomorrowAwakeEnd = dayAfterStart

        let todaySeed = Self.daySeed(for: todayStart, calendar: calendar)
        let tomorrowSeed = Self.daySeed(for: tomorrowStart, calendar: calendar)

        let todayDates = PromptPlanner.plan(
            prefs: prefs, awakeStart: todayAwakeStart, awakeEnd: todayAwakeEnd, seed: todaySeed, calendar: calendar
        )
        let tomorrowDates = PromptPlanner.plan(
            prefs: prefs, awakeStart: tomorrowAwakeStart, awakeEnd: tomorrowAwakeEnd, seed: tomorrowSeed, calendar: calendar
        )
        return (todayDates + tomorrowDates).sorted()
    }

    private func removePendingPromptRequests() {
        center.getPendingNotificationRequests { [center] requests in
            let identifiers = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(NotificationIdentifiers.promptPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    // MARK: - Next alert readout

    /// Reads the soonest pending DISPATCH_PROMPT (or snooze) trigger date,
    /// for the settings UI's "next alert" caption.
    func nextPromptDate(completion: @escaping @Sendable (Date?) -> Void) {
        center.getPendingNotificationRequests { requests in
            let dates = requests.compactMap { request -> Date? in
                let nextDate: Date? = switch request.trigger {
                case let calendar as UNCalendarNotificationTrigger:
                    calendar.nextTriggerDate()
                case let interval as UNTimeIntervalNotificationTrigger:
                    interval.nextTriggerDate()
                default:
                    nil
                }
                return nextDate
            }
            completion(dates.min())
        }
    }

    // MARK: - Delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        Task { @MainActor in
            switch actionIdentifier {
            case NotificationIdentifiers.snoozeAction:
                scheduleSnooze()
            case NotificationIdentifiers.answerYesAction:
                fileQuickAnswer(isYes: true)
            case NotificationIdentifiers.answerNoAction:
                fileQuickAnswer(isYes: false)
            default:
                // Default tap (including UNNotificationDefaultActionIdentifier)
                // opens the app into a new regular survey.
                pendingSurveyRequest = SurveyRequest(kind: .regular, trigger: .notification)
            }
            completionHandler()
        }
    }

    /// Set by the delegate on notification tap; ContentView/HomeView observe
    /// this via the environment and present SurveyFlowView, then clear it.
    var pendingSurveyRequest: SurveyRequest?

    private func scheduleSnooze() {
        let identifier = "\(NotificationIdentifiers.snoozePrefix)\(UUID().uuidString)"
        let content = Self.makeContent()
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 15 * 60, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request) { error in
            if let error {
                notificationLog.error("failed to schedule snooze: \(error, privacy: .public)")
            }
        }
    }

    private func fileQuickAnswer(isYes: Bool) {
        let context = ModelContext(container)
        guard let question = Self.firstEnabledYesNoQuestion(in: context) else { return }

        let ref = QuestionRef(
            uniqueIdentifier: question.uniqueIdentifier,
            prompt: question.prompt,
            type: question.type
        )
        let choiceIndex = isYes ? 0 : 1
        let value: AnswerValue
        if question.choices.indices.contains(choiceIndex) {
            value = .options([question.choices[choiceIndex]])
        } else {
            value = .options([isYes ? "Yes" : "No"])
        }
        let draft = AnswerDraft(question: ref, value: value)

        do {
            try ReportBuilder.save(
                kind: .regular,
                trigger: .notification,
                date: Date(),
                timeZone: .current,
                outcomes: [:],
                answers: [draft],
                in: context
            )
        } catch {
            notificationLog.error("failed to save quick answer report: \(error, privacy: .public)")
        }
    }

    // MARK: - Helpers

    private static func makeContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Time to report"
        content.body = "What are you up to right now?"
        content.sound = .default
        content.categoryIdentifier = NotificationIdentifiers.category
        return content
    }

    private static func firstEnabledYesNoQuestion(in context: ModelContext) -> Question? {
        let descriptor = FetchDescriptor<Question>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        guard let questions = try? context.fetch(descriptor) else { return nil }
        return questions.first {
            $0.isEnabled && $0.type == .yesNo && $0.reportKinds.contains(.regular)
        }
    }

    /// Day's `yyyyMMdd` digits as a UInt64 — stable within a calendar day,
    /// varies day to day, so the schedule doesn't repeat but doesn't churn
    /// on every re-plan either.
    static func daySeed(for date: Date, calendar: Calendar) -> UInt64 {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 2000
        let month = components.month ?? 1
        let day = components.day ?? 1
        let value = year * 10_000 + month * 100 + day
        return UInt64(max(0, value))
    }

    private static let isoDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        return formatter
    }()
}
