import AppIntents
import SwiftUI
import WidgetKit

/// One-tap "new report" from Control Center (and the lock screen's control
/// slots / Action button assignment). The button's action is
/// `StartReportControlIntent` — an `OpenIntent` compiled into BOTH this
/// extension and the app (see project.yml), so the system opens the app and
/// runs the intent's perform() in the app process. No deep-link round trip.
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
