import DispatchKit
import Foundation
import Observation

/// A pending survey to present, identified so it can drive a
/// `fullScreenCover(item:)` from anywhere in the view hierarchy — not just
/// from the view that triggered it. This is the landing pad for Plan 4's
/// notification/intent-triggered surveys, which won't originate from HomeView.
struct SurveyRequest: Identifiable, Equatable {
    let id = UUID()
    let kind: ReportKind
    let trigger: ReportTrigger
    /// When set, this is a backdated report: sensor capture is skipped
    /// entirely and the report is saved at this date with `isBackdated = true`.
    var overrideDate: Date?
    /// When set, the survey is scoped to this PromptGroup's questions and
    /// the saved report records the group (plan 12).
    var promptGroupID: String?
}

@MainActor
@Observable
final class SurveyPresenter {
    var request: SurveyRequest?
}
