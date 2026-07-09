import Foundation
import SwiftData

/// The shared quick-answer path: a MINIMAL report (the single answered
/// Yes/No question, NO sensor capture) filed without opening the app.
/// Two callers share it — the notification quick-answer actions
/// (`NotificationScheduler`, trigger `.notification`) and the interactive
/// widget buttons (`QuickAnswerIntent`, trigger `.widget`). Sensor capture
/// requires async permission/background work that is out of budget for
/// both contexts; users who want a full sensor-backed report open the app.
public enum QuickAnswerFiler {
    /// The question quick answers target: the first (by sort order) enabled
    /// regular-kind Yes/No question, nil when none exists.
    public static func firstEnabledYesNoQuestion(in context: ModelContext) -> Question? {
        let descriptor = FetchDescriptor<Question>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        guard let questions = try? context.fetch(descriptor) else { return nil }
        return questions.first {
            $0.isEnabled && $0.type == .yesNo && $0.reportKinds.contains(.regular)
        }
    }

    /// Files the minimal quick-answer report: one `.options` response for
    /// `question` carrying the choice at `choiceIndex` (0 = affirmative,
    /// 1 = negative), falling back to literal "Yes"/"No" when the question
    /// has no stored choice at that index.
    @discardableResult
    public static func file(
        question: Question,
        choiceIndex: Int,
        trigger: ReportTrigger,
        date: Date = Date(),
        in context: ModelContext
    ) throws -> Report {
        let ref = QuestionRef(
            uniqueIdentifier: question.uniqueIdentifier,
            prompt: question.prompt,
            type: question.type
        )
        let value: AnswerValue
        if question.choices.indices.contains(choiceIndex) {
            value = .options([question.choices[choiceIndex]])
        } else {
            value = .options([choiceIndex == 0 ? "Yes" : "No"])
        }
        return try ReportBuilder.save(
            kind: .regular,
            trigger: trigger,
            date: date,
            timeZone: .current,
            outcomes: [:],
            answers: [AnswerDraft(question: ref, value: value)],
            in: context
        )
    }
}
