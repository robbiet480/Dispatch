import SwiftUI
import WidgetKit

/// Complication skeleton (Task 1): placeholder rendering only; the
/// shared-store snapshot fetch and per-family layouts land in Task 5.
struct WatchStatusEntry: TimelineEntry {
    let date: Date
}

struct WatchStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchStatusEntry {
        WatchStatusEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchStatusEntry) -> Void) {
        completion(WatchStatusEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchStatusEntry>) -> Void) {
        completion(Timeline(entries: [WatchStatusEntry(date: Date())], policy: .never))
    }
}

struct WatchStatusWidgetView: View {
    var entry: WatchStatusEntry

    var body: some View {
        Text("—")
            .containerBackground(.clear, for: .widget)
    }
}

struct DispatchWatchStatusWidget: Widget {
    let kind = "DispatchWatchStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchStatusProvider()) { entry in
            WatchStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Dispatch")
        .description("Streak and today's report count.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
