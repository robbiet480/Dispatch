import DispatchKit
import SwiftUI
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// nil ⇒ the shared store isn't readable yet — render the placeholder.
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(),
                      snapshot: WidgetSnapshot(lastReportDate: Date().addingTimeInterval(-3600),
                                               todayCount: 3, streakDays: 5,
                                               nextPromptDate: Date().addingTimeInterval(5400)))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(SnapshotEntry(date: Date(), snapshot: SharedStoreReader.snapshot()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let entry = SnapshotEntry(date: now, snapshot: SharedStoreReader.snapshot(now: now))
        // "Time since last report" uses relative date text (self-updating);
        // counts/streak flip at midnight — refresh at the next of (30 min,
        // midnight). The app also pokes reloadAllTimelines on save/replan.
        let halfHour = now.addingTimeInterval(30 * 60)
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 60 * 60)
        completion(Timeline(entries: [entry], policy: .after(min(halfHour, midnight))))
    }
}

struct DispatchStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.robbie.Dispatch.widgets.status", provider: SnapshotProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        }
        .configurationDisplayName("Dispatch")
        .description("Time since your last report, today's count, and your streak.")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            inline
        case .systemMedium:
            medium
        default:
            small
        }
    }

    // MARK: - Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer()
            lastReportBlock
            Spacer()
            Text(todayLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                header
                Spacer()
                lastReportBlock
                Text(todayLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                if let snapshot = entry.snapshot {
                    if snapshot.streakDays > 0 {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(snapshot.streakDays)")
                                .font(.title2.weight(.bold))
                            Text("DAY STREAK")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let next = snapshot.nextPromptDate, next > entry.date {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(next, style: .time)
                                .font(.headline)
                            Text("NEXT PROMPT")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Link(destination: URL(string: "dispatch://report?trigger=widget")!) {
                    Label("New Report", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
            }
        }
    }

    private var header: some View {
        Label("Dispatch", systemImage: "hexagon.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
    }

    @ViewBuilder
    private var lastReportBlock: some View {
        if let last = entry.snapshot?.lastReportDate {
            VStack(alignment: .leading, spacing: 0) {
                Text(last, style: .relative)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("SINCE LAST REPORT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No reports yet")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private var todayLine: String {
        let count = entry.snapshot?.todayCount ?? 0
        return count == 1 ? "1 report today" : "\(count) reports today"
    }

    // MARK: - Lock screen

    private var circular: some View {
        VStack(spacing: 0) {
            Image(systemName: "hexagon.fill")
                .font(.caption2)
            Text("\(entry.snapshot?.todayCount ?? 0)")
                .font(.title3.weight(.bold))
            Text("TODAY")
                .font(.system(size: 8, weight: .semibold))
        }
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
            Text(todayLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
