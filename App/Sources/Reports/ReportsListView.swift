import DispatchKit
import SwiftData
import SwiftUI

struct ReportsListView: View {
    @Environment(\.modelContext) private var context
    @Query private var reports: [Report]
    @Query private var tokenEntities: [TokenEntity]
    @Query private var personEntities: [PersonEntity]
    @Environment(ThemeStore.self) private var themeStore
    @Environment(SurveyPresenter.self) private var surveyPresenter
    @Environment(AppLockStore.self) private var appLockStore

    private var theme: Theme { themeStore.theme }

    @State private var searchQuery = ""
    @State private var showingBackfillSheet = false
    @State private var backfillDate = Date()

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
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    backfillDate = Date()
                    showingBackfillSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("backfill-button")
            }
        }
        // Gated on the lock, mirroring ContentView's survey-cover pattern: if the
        // lock engages while this sheet is up, the getter flips to false so the
        // sheet dismisses and the lock's fullScreenCover in ContentView can present
        // without this sheet blocking it.
        .sheet(isPresented: Binding(
            get: { showingBackfillSheet && !appLockStore.isLocked },
            set: { showingBackfillSheet = $0 })) {
            backfillSheet
        }
    }

    // MARK: - Backfill

    private var backfillSheet: some View {
        NavigationStack {
            VStack {
                DatePicker("Report date", selection: $backfillDate, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .padding()
                Spacer()
            }
            .navigationTitle("Backdated Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingBackfillSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        showingBackfillSheet = false
                        surveyPresenter.request = SurveyRequest(kind: .regular, trigger: .manual,
                                                                overrideDate: backfillDate)
                    }
                    .accessibilityIdentifier("backfill-continue")
                }
            }
        }
    }

    // MARK: - Stats header

    private var statsHeader: some View {
        // Stats reflect the same set the list shows (filtered while searching).
        let primary = ReportsOverview.stats(from: filteredReports)
        // tokenCount/personCount are deliberately global (all-time token/people
        // vocabulary from the @Query'd entities) rather than derived from
        // filteredReports — even while searching, this second stats page shows
        // the full vocabulary size, not a count scoped to the search results.
        let secondary = ReportsOverview.secondaryStats(
            reports: filteredReports,
            tokenCount: tokenEntities.count,
            personCount: personEntities.count
        )

        return TabView {
            statsPage([
                (String(primary.reports), "REPORTS"),
                (String(primary.days), "DAYS"),
                (String(format: "%.1f", primary.avgPerDay), "AVG/DAY"),
            ])
            statsPage([
                (String(secondary.tokens), "TOKENS"),
                (String(secondary.locations), "LOCATIONS"),
                (String(secondary.people), "PEOPLE"),
            ])
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .indexViewStyle(.page(backgroundDisplayMode: .never))
        .frame(height: 120)
    }

    private func statsPage(_ stats: [(number: String, label: String)]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                if index > 0 {
                    Rectangle()
                        .fill(.white.opacity(0.3))
                        .frame(width: 1, height: 44)
                }
                VStack(spacing: 4) {
                    Text(stat.number)
                        .font(.system(size: 32, weight: .light))
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
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.reports, id: \.uniqueIdentifier) { report in
                        NavigationLink(destination: ReportDetailView(report: report)) {
                            ReportRowView(report: report)
                        }
                        .listRowBackground(Color.white.opacity(0.12))
                        .accessibilityIdentifier("report-row")
                    }
                    .onDelete { offsets in
                        delete(at: offsets, in: section)
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $searchQuery, prompt: "Search reports")
        .accessibilityIdentifier("reports-list")
    }

    private func delete(at offsets: IndexSet, in section: DaySection) {
        for offset in offsets {
            let report = section.reports[offset]
            SpotlightIndexer.deindex(reportID: report.uniqueIdentifier)
            context.delete(report)
        }
        try? context.save()
        // Widgets read the shared store directly but get no change
        // notifications — poke them after a deletion, same as report save.
        WidgetRefresher.reload()
    }
}

struct ReportRowView: View {
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
