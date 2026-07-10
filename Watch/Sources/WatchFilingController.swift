import DispatchKit
import Foundation
import Observation
import os
import SwiftData

let watchFilingLog = Logger(subsystem: "io.robbie.Dispatch.watchkitapp", category: "filing")

/// The watch's shared filing path (plan 19): sensor capture + minimal report
/// save, used by the quick-answer card, the per-question input views, and
/// the notification Yes/No actions. Same `CaptureCoordinator`/`ReportBuilder`
/// flow as the phone — same 10s default timeout, same partial-result
/// semantics; a hung sensor yields `unavailable` and the report files
/// regardless. Capture never blocks filing beyond the coordinator's cap.
@MainActor
enum WatchReportFiler {
    /// Files a minimal report for the question with `questionID`, capturing
    /// watch-side sensor context first. Re-fetches the question by ID before
    /// saving (stale-UI rule — the row that was tapped may have been
    /// disabled/deleted/re-typed by a sync since it rendered); returns nil
    /// without saving when it no longer matches `expectedType`.
    @discardableResult
    static func file(
        questionID: String,
        expectedType: QuestionType,
        value: AnswerValue,
        in context: ModelContext
    ) async throws -> Report? {
        // Stale-UI rule: re-fetch by ID, re-check eligibility.
        var descriptor = FetchDescriptor<Question>(
            predicate: #Predicate { $0.uniqueIdentifier == questionID }
        )
        descriptor.fetchLimit = 1
        guard let question = try context.fetch(descriptor).first,
              question.isEnabled, question.type == expectedType,
              question.reportKinds.contains(.regular) else {
            watchFilingLog.error("question \(questionID, privacy: .public) missing or no longer answerable — not filing")
            return nil
        }
        let ref = QuestionRef(
            uniqueIdentifier: question.uniqueIdentifier,
            prompt: question.prompt,
            type: question.type
        )

        // Watch-side sensor capture: same coordinator, watch provider set,
        // the watch's OWN SensorSettings (per-device toggles, default ON).
        let since = DispatchStore.lastReportDate(in: context)
        var outcomes: [SensorKind: SensorOutcome] = [:]
        let stream = CaptureCoordinator.capture(
            providers: WatchProviders.all(since: since),
            settings: SensorSettings()
        )
        for await event in stream {
            outcomes[event.kind] = event.outcome
        }

        return try ReportBuilder.save(
            kind: .regular,
            trigger: .watch,
            date: Date(),
            timeZone: .current,
            outcomes: outcomes,
            answers: [AnswerDraft(question: ref, value: value)],
            in: context
        )
    }

    /// Quick answer: choice at `choiceIndex` (0 = affirmative, 1 = negative)
    /// with the same title fallback the phone's QuickAnswerFiler uses —
    /// but through the full watch filing path (capture included).
    @discardableResult
    static func fileQuickAnswer(
        question: Question, choiceIndex: Int, in context: ModelContext
    ) async throws -> Report? {
        let value: AnswerValue
        if question.choices.indices.contains(choiceIndex) {
            value = .options([question.choices[choiceIndex]])
        } else {
            value = .options([choiceIndex == 0 ? "Yes" : "No"])
        }
        return try await file(
            questionID: question.uniqueIdentifier,
            expectedType: .yesNo,
            value: value,
            in: context
        )
    }
}
