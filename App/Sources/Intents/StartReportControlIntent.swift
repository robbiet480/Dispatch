import AppIntents

/// Control Center "New Report" intent, following Apple's "Creating controls
/// to perform actions across the system" → "Open your app with a control":
/// an intent conforming to `OpenIntent` whose source file has Target
/// Membership in BOTH the app and the widget extension (see project.yml —
/// this file is listed in both DispatchApp and DispatchWidgets sources).
/// The widget copy exists only so the control's button can reference the
/// intent; when the control is tapped the system opens the app and runs
/// `perform()` IN THE APP process, where it can reach in-app state directly —
/// no OpenURLIntent / deep-link round trip.
struct StartReportControlIntent: OpenIntent {
    static let title: LocalizedStringResource = "Start Report"
    static let description = IntentDescription("Opens Dispatch and starts a new report.")

    @Parameter(title: "Target", default: .newReport)
    var target: ReportControlTarget

    /// Set by DispatchApp at launch (routes through AppActions →
    /// SurveyPresenter, the same path StartReportIntent uses, so the survey
    /// still flows through ContentView's lock-gated choke point). Remains nil
    /// in the widget extension process, where perform() never runs.
    @MainActor static var startReportInApp: (@MainActor () -> Void)?

    @MainActor
    func perform() async throws -> some IntentResult {
        Self.startReportInApp?()
        return .result()
    }
}

/// `OpenIntent` requires a `target` parameter; the control has exactly one
/// action, so this is a single-case enum.
enum ReportControlTarget: String, AppEnum {
    case newReport

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Report"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .newReport: "New Report",
    ]
}
