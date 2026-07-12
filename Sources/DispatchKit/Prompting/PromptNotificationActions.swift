import Foundation
import SwiftData

/// Decides which action buttons the interactive `DISPATCH_PROMPT` prompt
/// notification offers, given the current question set.
///
/// The quick-answer Yes/No actions may ONLY be offered when an eligible
/// Yes/No question exists (`QuickAnswerFiler.firstEnabledYesNoQuestion`) —
/// tapping "Yes"/"No" files that question's answer through the shared
/// quick-answer filer, and that filer drops the action when there is no
/// Yes/No question. Attaching Yes/No to a prompt whose body is an open-text
/// question (the generic "What are you up to right now?" fallback) shipped a
/// bug: the buttons rendered on the iPhone AND, forwarded, on the Apple Watch,
/// but tapping them filed NOTHING (the filer's nil-question guard). An
/// open-text prompt must instead offer only Snooze, so a plain tap opens the
/// app to answer — matching the iOS default-action behavior.
///
/// This lives in the kit (not inline in `NotificationScheduler`) so the
/// decision is unit-testable under `swift test`.
public enum PromptNotificationActions {
    /// Ordered action identifiers for the `DISPATCH_PROMPT` category, given
    /// whether an eligible Yes/No question exists. Yes/No come first (the
    /// primary affordance), Snooze last.
    public static func identifiers(hasYesNoQuestion: Bool) -> [String] {
        var identifiers: [String] = []
        // Yes/No quick answers ONLY for a boolean question — otherwise the
        // buttons file nothing (the quick-answer filer's nil-question guard)
        // and mislead the user, on the iPhone and the forwarded watch alike.
        if hasYesNoQuestion {
            identifiers.append(NotificationIdentifiers.answerYesAction)
            identifiers.append(NotificationIdentifiers.answerNoAction)
        }
        // Snooze is always valid — it re-delivers the prompt regardless of
        // question type — so an open-text prompt still offers it (tap-through
        // opens the app to answer, matching the iOS default action).
        identifiers.append(NotificationIdentifiers.snoozeAction)
        return identifiers
    }

    /// Convenience: resolves `hasYesNoQuestion` from the store so callers
    /// (and tests) can drive the decision straight from the question set.
    public static func identifiers(in context: ModelContext) -> [String] {
        identifiers(
            hasYesNoQuestion: QuickAnswerFiler.firstEnabledYesNoQuestion(in: context) != nil
        )
    }
}
