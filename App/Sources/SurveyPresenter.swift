import DispatchKit
import Foundation
import Observation

/// A pending survey to present, identified so it can drive a
/// `fullScreenCover(item:)` from anywhere in the view hierarchy — not just
/// from the view that triggered it. This is the landing pad for Plan 4's
/// notification/intent-triggered surveys, which won't originate from HomeView.
struct SurveyRequest: Identifiable {
    let id = UUID()
    let kind: ReportKind
    let trigger: ReportTrigger
}

@MainActor
@Observable
final class SurveyPresenter {
    var request: SurveyRequest?
}
