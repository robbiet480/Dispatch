import AppIntents
import DispatchKit
import Foundation
import os
import SwiftData
import UIKit
import WidgetKit

private let quickAnswerLog = Logger(subsystem: "io.robbie.Dispatch", category: "quick-answer-intent")

/// Interactive-widget quick answer: the medium status widget's Yes/No
/// buttons invoke this intent to file the answer without opening the app.
///
/// Dual target membership (same pattern as StartReportControlIntent — see
/// project.yml): `Button(intent:)` requires the intent type to be compiled
/// into the widget extension, and App Intents metadata extraction wants it
/// in the app too.
///
/// EXECUTION PROCESS (probe-verified on the iOS 26.5 simulator, plan 17):
/// tapping the widget button runs `perform()` in the WIDGET EXTENSION
/// process (`ProcessInfo.processName` logged "DispatchWidgets", pid
/// distinct from the app's) — NOT in the app, and the app is NOT launched.
/// Consequences, side effect by side effect:
/// - report save: works here — the shared App Group store is opened
///   writable (`allowsSave: true`, `cloudKitDatabase: .none`; only the app
///   process mirrors to CloudKit, and its history-tracking ingest picks the
///   row up at next launch/foreground).
/// - `lastActedAt` + nag-chain cancellation: NOT reachable from this
///   process (app-sandbox `.standard` defaults; the extension's
///   UNUserNotificationCenter manages the extension's own notification
///   identity, not the app's pending requests) — so `perform()` persists a
///   pending-action marker in the App Group defaults that the app drains at
///   next launch/foreground (`NotificationScheduler
///   .drainWidgetQuickAnswerActions`).
/// - widget reload: `WidgetCenter` works from the extension process;
///   reloading refreshes counts and flips the transient "Filed ✓" state
///   (`WidgetQuickAnswerMarker.filedAt`).
struct QuickAnswerIntent: AppIntent {
    static let title: LocalizedStringResource = "Answer Quick Question"
    static let description = IntentDescription(
        "Answers your quick Yes/No question and files a minimal report."
    )
    /// Widget-internal: the buttons carry fully-configured instances; the
    /// raw question-ID/choice-index parameters are meaningless in Shortcuts.
    static let isDiscoverable = false

    @Parameter(title: "Question ID")
    var questionID: String

    @Parameter(title: "Choice Index")
    var choiceIndex: Int

    init() {}

    init(questionID: String, choiceIndex: Int) {
        self.questionID = questionID
        self.choiceIndex = choiceIndex
    }

    func perform() async throws -> some IntentResult {
        // Probe (plan 17): identifies the executing process in the unified
        // log — kept permanently; it's one line per tap and it documents
        // the process contract this file's behavior depends on.
        quickAnswerLog.info("perform() in process \(ProcessInfo.processInfo.processName, privacy: .public) pid \(ProcessInfo.processInfo.processIdentifier)")

        // Device provenance (plan 19): this perform() runs in the WIDGET
        // EXTENSION process (probe above), where the app's launch-time
        // injection never ran — inject before filing so widget-filed reports
        // carry the same provenance as in-app ones. Unconditional read; the
        // generic name is expected until the entitlement grant (see
        // DeviceIdentity).
        DeviceIdentity.deviceName = await UIDevice.current.name

        // Double-fire guard (build-14 review): two rapid taps on a widget
        // button each invoke perform() before the first filing's reload
        // replaces the buttons with "Filed ✓" — without this, each tap files
        // a report. A filing within the suppression window means this
        // invocation is the same tap burst: reload (in case the first tap's
        // reload raced) and return without filing.
        if let defaults = UserDefaults(suiteName: StoreLocation.appGroupID),
           WidgetQuickAnswerMarker.shouldSuppressDoubleFire(
               lastFiledAt: WidgetQuickAnswerMarker.filedAt(in: defaults)
           ) {
            quickAnswerLog.info("suppressed double-fire for \(questionID, privacy: .public) — filed within the last \(Int(WidgetQuickAnswerMarker.doubleFireSuppressionWindow))s")
            WidgetCenter.shared.reloadAllTimelines()
            return .result()
        }

        guard let storeURL = StoreLocation.appGroupURL(),
              FileManager.default.fileExists(atPath: storeURL.path) else {
            quickAnswerLog.error("no shared store — cannot file quick answer")
            return .result()
        }
        do {
            let schema = Schema(DispatchStore.allModels)
            let config = ModelConfiguration(
                schema: schema, url: storeURL, allowsSave: true, cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            // Re-fetch by ID: the timeline that rendered the button may be
            // stale (question deleted/disabled/re-ordered since) — never
            // file against a question that no longer matches.
            let targetID = questionID
            var descriptor = FetchDescriptor<Question>(
                predicate: #Predicate { $0.uniqueIdentifier == targetID }
            )
            descriptor.fetchLimit = 1
            // Eligibility mirrors QuickAnswerFiler.firstEnabledYesNoQuestion
            // exactly — including the regular-kind check, so a question
            // re-scoped to wake-only since the timeline rendered can't file.
            guard let question = try context.fetch(descriptor).first,
                  question.isEnabled, question.type == .yesNo,
                  question.reportKinds.contains(.regular) else {
                quickAnswerLog.error("question \(targetID, privacy: .public) missing or no longer quick-answerable — reloading timelines instead")
                WidgetCenter.shared.reloadAllTimelines()
                return .result()
            }
            let report = try QuickAnswerFiler.file(
                question: question, choiceIndex: choiceIndex, trigger: .widget, in: context
            )
            // KNOWN WINDOW (accepted, build-14 review minor): a crash between
            // the save above and this marker write loses the marker, not the
            // report — fail-safe direction is a lost nag-cancel (one extra
            // nag, self-healing), never a duplicate report.
            if let defaults = UserDefaults(suiteName: StoreLocation.appGroupID) {
                WidgetQuickAnswerMarker.recordFiled(at: Date(), in: defaults)
                // Webhook queue (plan 24): this EXTENSION process enqueues
                // only — delivery is the app's job, drained at its next
                // launch/foreground (right after the marker drain above is
                // applied). Gated inside on the mirrored enabled flag.
                WebhookQueue.enqueue(reportID: report.uniqueIdentifier, in: defaults)
            }
            quickAnswerLog.info("filed widget quick answer (choice \(choiceIndex)) for \(targetID, privacy: .public)")
        } catch {
            quickAnswerLog.error("widget quick answer failed: \(error, privacy: .public)")
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
