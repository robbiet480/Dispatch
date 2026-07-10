import DispatchKit
import SwiftUI
import WidgetKit

/// Watch complications (plan 19): streak + today count ONLY, rendered from
/// `WidgetSnapshot` over a read-only shared-store fetch — the watch-side
/// mirror of the phone widget architecture. No `nextPromptDate` slot in any
/// family (it is always nil on the watch — see WatchSharedStoreReader).
struct WatchStatusEntry: TimelineEntry {
    let date: Date
    /// nil ⇒ the shared store isn't readable yet — render the placeholder.
    let snapshot: WidgetSnapshot?
}

struct WatchStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchStatusEntry {
        WatchStatusEntry(
            date: Date(),
            snapshot: WidgetSnapshot(lastReportDate: Date().addingTimeInterval(-3600),
                                     todayCount: 3, streakDays: 5)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchStatusEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(WatchStatusEntry(date: Date(), snapshot: WatchSharedStoreReader.snapshot()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchStatusEntry>) -> Void) {
        let now = Date()
        let entry = WatchStatusEntry(date: now, snapshot: WatchSharedStoreReader.snapshot(now: now))
        // Counts/streak flip at midnight; the relative last-report text is
        // self-updating. The watch app also pokes reloadAllTimelines on
        // save/foreground, so timeline policy only backstops staleness.
        let halfHour = now.addingTimeInterval(30 * 60)
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 60 * 60)
        completion(Timeline(entries: [entry], policy: .after(min(halfHour, midnight))))
    }
}

struct WatchStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchStatusEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCorner:
                corner
            case .accessoryInline:
                inline
            case .accessoryRectangular:
                rectangular
            default:
                circular
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var todayCount: Int { entry.snapshot?.todayCount ?? 0 }
    private var streakDays: Int { entry.snapshot?.streakDays ?? 0 }

    private var todayLine: String {
        todayCount == 1 ? "1 report today" : "\(todayCount) reports today"
    }

    private var circular: some View {
        VStack(spacing: 0) {
            Image(systemName: "hexagon.fill")
                .font(.caption2)
            Text("\(todayCount)")
                .font(.title3.weight(.bold))
            Text("TODAY")
                .font(.system(size: 8, weight: .semibold))
        }
        // One element — otherwise VoiceOver reads "Hexagon, 3, TODAY".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(todayLine)
    }

    /// Corner: compact count in the corner, streak in the curved widget
    /// label (the corner-specific text slot).
    private var corner: some View {
        Text("\(todayCount)")
            .font(.title3.weight(.bold))
            .widgetLabel {
                Text(streakDays > 0 ? "\(streakDays) day streak" : "Dispatch")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(streakDays > 0
                ? "\(todayLine), \(streakDays) day streak"
                : todayLine)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Dispatch", systemImage: "hexagon.fill")
                .font(.caption2.weight(.semibold))
            if let last = entry.snapshot?.lastReportDate {
                Text(last, style: .relative)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("No reports yet")
                    .font(.headline)
            }
            // Streak + today only — deliberately no next-prompt line.
            Text(streakDays > 0 ? "\(todayLine) · \(streakDays)d streak" : todayLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var inline: some View {
        if let last = entry.snapshot?.lastReportDate {
            Text("Last report \(last, style: .relative) ago")
        } else {
            Text("Dispatch — no reports yet")
        }
    }
}

struct DispatchWatchStatusWidget: Widget {
    let kind = "io.robbie.Dispatch.watchkitapp.widgets.status"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchStatusProvider()) { entry in
            WatchStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Dispatch")
        .description("Streak and today's report count.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular,
                            .accessoryInline, .accessoryCorner])
    }
}
