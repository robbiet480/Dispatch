import SwiftUI
import WidgetKit

@main
struct DispatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DispatchStatusWidget()
        DispatchControlWidget()
    }
}
