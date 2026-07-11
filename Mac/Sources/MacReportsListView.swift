import DispatchKit
import SwiftData
import SwiftUI

/// The split view's sidebar: stats header, kit-backed search, day-sectioned
/// selection list. Deletion is context-menu + ⌫ (onDeleteCommand), both
/// behind a confirmation — Mac keyboards make accidental ⌫ too cheap for an
/// unguarded destructive action.
struct MacReportsListView: View {
    @Environment(\.modelContext) private var context
    @Query private var reports: [Report]
    @Query private var tokenEntities: [TokenEntity]
    @Query private var personEntities: [PersonEntity]
    @Environment(ThemeStore.self) private var themeStore

    @Binding var selection: String?
    // Hoisted to MacRootView so the dashboard's charts filter with the same
    // query the sidebar list and stat tiles use.
    @Binding var searchQuery: String


    @SwiftUI.FocusState private var isSearchFocused: Bool
    @State private var pendingDelete: Report?

    private var theme: Theme { themeStore.theme }
    private var filteredReports: [Report] { ReportSearch.filter(reports, query: searchQuery) }
    private var sections: [DaySection] { ReportsOverview.sections(from: filteredReports) }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                statsHeader
                reportsList
            }
        }
        .navigationTitle("Reports")
        .searchable(text: $searchQuery, prompt: "Search reports")
        .searchFocused($isSearchFocused)
        // ⌘F focuses the search field — same zero-size hidden-anchor trick
        // as the iPad list (plan 27); the Mac app has no survey sheet to
        // guard against.
        .background {
            Button("") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .confirmationDialog(
            "Delete this report?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { report in
            Button("Delete Report", role: .destructive) { delete(report) }
            Button("Cancel", role: .cancel) {}
        } message: { report in
            Text("The report from \(report.date.formatted(date: .abbreviated, time: .shortened)) will be deleted everywhere it syncs. This cannot be undone.")
        }
    }

    // MARK: - Stats header

    /// The iPad sidebar's paged stats, flattened: a Mac sidebar has no page
    /// dots, so both stat rows show at once.
    private var statsHeader: some View {
        let primary = ReportsOverview.stats(from: filteredReports)
        let secondary = ReportsOverview.secondaryStats(
            reports: filteredReports,
            tokenCount: tokenEntities.count,
            personCount: personEntities.count
        )
        return VStack(spacing: 10) {
            statsRow([
                (String(primary.reports), "REPORTS"),
                (String(primary.days), "DAYS"),
                (String(format: "%.1f", primary.avgPerDay), "AVG/DAY"),
            ])
            statsRow([
                (String(secondary.tokens), "TOKENS"),
                (String(secondary.locations), "LOCATIONS"),
                (String(secondary.people), "PEOPLE"),
            ])
        }
        .padding(.vertical, 12)
    }

    private func statsRow(_ stats: [(number: String, label: String)]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                if index > 0 {
                    Rectangle()
                        .fill(.white.opacity(0.3))
                        .frame(width: 1, height: 32)
                }
                VStack(spacing: 2) {
                    Text(stat.number)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(stat.label)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - List

    private var reportsList: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.reports, id: \.uniqueIdentifier) { report in
                        MacReportRow(report: report)
                            .tag(report.uniqueIdentifier)
                            .listRowBackground(rowBackground(for: report))
                            .contextMenu {
                                Button("Delete Report…", role: .destructive) {
                                    pendingDelete = report
                                }
                            }
                            .accessibilityIdentifier("report-row")
                    }
                } header: {
                    HStack {
                        Text(section.weekday)
                        Spacer()
                        Text(section.dateLabel)
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .scrollContentBackground(.hidden)
        // ⌫ on the selected row (macOS's List delete command) routes through
        // the same confirmation as the context menu.
        .onDeleteCommand {
            guard let selection,
                  let report = reports.first(where: { $0.uniqueIdentifier == selection }) else { return }
            pendingDelete = report
        }
        .accessibilityIdentifier("reports-list")
    }

    private func rowBackground(for report: Report) -> Color {
        selection == report.uniqueIdentifier
            ? Color.white.opacity(0.25)
            : Color.white.opacity(0.12)
    }

    private func delete(_ report: Report) {
        // Clear the detail pane BEFORE the row vanishes (plan 27's
        // dangling-selection lesson).
        if selection == report.uniqueIdentifier {
            selection = nil
        }
        context.delete(report)
        try? context.save()
        pendingDelete = nil
    }
}

/// Mac twin of the iOS ReportRowView — time, kind glyph, place/kind subtitle.
struct MacReportRow: View {
    let report: Report

    var body: some View {
        HStack(spacing: 12) {
            Text(timeLabel)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)

            if let icon = kindIcon {
                Image(systemName: icon)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: report.timeZoneIdentifier) ?? .gmt
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: report.date)
    }

    private var kindIcon: String? {
        switch report.kind {
        case .sleep: "moon.fill"
        case .wake: "sun.max.fill"
        case .regular: nil
        }
    }

    private var subtitle: String {
        if let placemark = report.location?.placemark {
            let parts = [placemark.locality, placemark.administrativeArea]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            if !parts.isEmpty {
                return parts.joined(separator: ", ")
            }
        }
        switch report.kind {
        case .wake: return "Woke up"
        case .sleep: return "Went to sleep"
        case .regular: return "\(report.trigger.rawValue.capitalized) report"
        }
    }
}
