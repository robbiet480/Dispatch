import DispatchKit
import Foundation
import os
import SwiftData
import UserNotifications

let watchNotificationLog = Logger(subsystem: "io.robbie.Dispatch.watchkitapp", category: "notifications")

/// Handles actions on prompt notifications FORWARDED from the phone
/// (plan 19 design §v1-scope-5). The watch schedules NOTHING — no
/// `UNUserNotificationCenter.add`, no `requestAuthorization`, no category
/// registration anywhere in this target (grep-provable): scheduling
/// authority is 100% phone-side, and the system forwards the phone's local
/// notifications per its lock-state rules
/// (https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding).
///
/// MANDATORY PROBE (uncited platform behavior, four-strikes rule): Apple's
/// docs do not specify, for FORWARDED notifications, (a) which device's
/// delegate receives the `didReceive` response for a tapped action, or
/// (b) whether action buttons render on the watch without watch-side
/// category registration. Both delegates therefore log process + action +
/// request identifiers (the phone's logs in NotificationScheduler
/// .didReceive, this one below) and the user device script verifies on
/// hardware. The design holds under either outcome: if responses land
/// phone-side, the phone's existing handler files and the watch ships
/// tap-to-open (documented downgrade); if watch-side, the filing contract
/// below applies.
final class WatchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

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
        let requestIdentifier = response.notification.request.identifier
        // Probe line — pairs with the phone delegate's; on-hardware log
        // capture answers which process receives forwarded-action responses.
        watchNotificationLog.info("didReceive in process \(ProcessInfo.processInfo.processName, privacy: .public) action \(actionIdentifier, privacy: .public) request \(requestIdentifier, privacy: .public)")

        let container = self.container
        Task { @MainActor in
            switch WatchNotificationAction.route(actionIdentifier: actionIdentifier) {
            case .fileAnswer(let isYes):
                // Yes/No FILE directly on the watch via the shared filing
                // path (capture included) — one tap is one filed answer.
                // Mirroring uploads it; the phone reconciles lastActedAt/
                // nags on arrival (NotificationScheduler.syncedReportsArrived).
                let context = ModelContext(container)
                if let question = QuickAnswerFiler.firstEnabledYesNoQuestion(in: context) {
                    do {
                        _ = try await WatchReportFiler.fileQuickAnswer(
                            question: question, choiceIndex: isYes ? 0 : 1, in: context
                        )
                        WatchWidgetRefresher.reload()
                    } catch {
                        watchNotificationLog.error("notification quick answer failed: \(error, privacy: .public)")
                    }
                } else {
                    watchNotificationLog.error("no quick-answer question — notification action dropped")
                }
            case .snoozeNoOp:
                // Documented no-op (design §v1-scope-5): the watch cannot
                // schedule (double-prompt hazard — watch-local notifications
                // don't dedup against the phone's local prompts) and cannot
                // reach the phone's scheduler; a WatchConnectivity snooze
                // relay is deferred scope. The phone-side nag chain, if any,
                // keeps running. Dismiss + log.
                watchNotificationLog.info("snooze tapped on watch — documented no-op (scheduling stays phone-side)")
            case .openApp:
                // Plain tap: the system opens the app; the home screen
                // already leads with the quick-answer question.
                break
            }
            completionHandler()
        }
    }
}
