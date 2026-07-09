import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center intent lives in the WIDGET process, where the app's
/// `StartReportIntent` (which needs the in-app `AppActions` singleton) can't
/// run. It opens the app via the same `dispatch://report` deep link the home
/// screen widget's "New Report" button uses; `trigger=control` marks the
/// resulting report `.control` in history.
struct StartReportControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Report"
    static let description = IntentDescription("Opens Dispatch and starts a new report.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "dispatch://report?trigger=control")!))
    }
}

/// One-tap "new report" from Control Center (and the lock screen's control
/// slots / Action button assignment).
struct DispatchControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.robbie.Dispatch.widgets.control") {
            ControlWidgetButton(action: StartReportControlIntent()) {
                Label("New Report", systemImage: "hexagon.fill")
            }
        }
        .displayName("New Report")
        .description("Start a new Dispatch report.")
    }
}
