import DispatchKit
import SwiftData
import SwiftUI

/// The Mac dashboard — the Mac-native chrome (window background, "Dashboard"
/// nav title, and the Mac-specific "no reports yet, sync from iPhone" empty
/// state) wrapped around the shared `DashboardContentView` (Task 2.5). The
/// populated body — the memoized visualization rebuild, the filter bar
/// (`report-count`), and the card grid — now lives in that dual-target view
/// and is identical to the iPad's; only the surrounding chrome differs, so it
/// stays here. The Mac passes the adaptive grid columns (window resizes reflow
/// it for free) and its sidebar `searchQuery`; the filter surface stays the
/// Mac `MacFilterPopover` (see `DashboardContentView.filterButton`).
struct MacDashboardView: View {
    @Query private var reports: [Report]
    @Environment(ThemeStore.self) private var themeStore

    /// The sidebar's search query (owned by MacRootView): the dashboard's
    /// charts must aggregate the same search-filtered report set the sidebar
    /// list and stat tiles show, not all-reports totals.
    var searchQuery: String = ""

    private var theme: Theme { themeStore.theme }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            if reports.isEmpty {
                emptyState
            } else {
                // Grid only on the Mac (no pager, no bottom-strip dots), so the
                // selection binding is inert.
                DashboardContentView(
                    searchQuery: searchQuery,
                    columns: [GridItem(.adaptive(minimum: 340), spacing: 16)],
                    selectedQuestionID: .constant(nil)
                )
            }
        }
        .navigationTitle("Dashboard")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 96))
                .foregroundStyle(.white.opacity(0.35))
            Text("No reports yet")
                .font(.headline)
                .foregroundStyle(.white)
            Text("File reports on your iPhone or Apple Watch — they sync here through iCloud.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
        .accessibilityIdentifier("home-hexagon")
    }
}

/// Mac-native filter surface — the iOS filter sheet's content (active-
/// criteria chips, per-category value pickers from actual data, question
/// show/hide toggles) reorganized as a popover with disclosure groups. The
/// iOS `VisualizationFilterView` stays untouched (it leans on iOS-only
/// navigation-bar styling and inset-grouped lists).
struct MacFilterPopover: View {
    let questions: [Question]
    let reports: [Report]
    let filterStore: VisualizationFilterStore
    @Environment(\.modelContext) private var modelContext
    @State private var personNames: [String] = []
    @State private var tokenTexts: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Filter Visualizations")
                    .font(.headline)
                Spacer()
                if !filterStore.criteria.isEmpty {
                    Button("Clear") { filterStore.clearCriteria() }
                        .accessibilityIdentifier("viz-filter-clear")
                }
            }
            .padding()

            if !filterStore.criteria.isEmpty {
                activeCriteriaChips
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            Divider()

            List {
                Section("Filter by content") {
                    categoryGroup("People", pairs: personNames.map { ($0, .person($0)) })
                    categoryGroup("Places", pairs: placeNames.map { ($0, .place($0)) })
                    categoryGroup("Tokens", pairs: tokenTexts.map { ($0, .token($0)) })
                    categoryGroup("Months", pairs: monthPairs)
                    categoryGroup("Years", pairs: yearPairs)
                    categoryGroup("Ambient Audio", pairs: ReportFilter.AudioBucket.allCases.map {
                        ($0.displayName, .ambientAudio($0))
                    })
                    categoryGroup("Steps", pairs: ReportFilter.StepsBucket.allCases.map {
                        ($0.displayName, .steps($0))
                    })
                    categoryGroup("Weather", pairs: weatherConditions.map { ($0, .weather($0)) })
                }
                Section("Questions") {
                    ForEach(questions, id: \.uniqueIdentifier) { question in
                        Toggle(question.prompt, isOn: binding(for: question))
                    }
                }
            }
            .accessibilityIdentifier("viz-filter-list")

            Divider()
            Text("Results are only shown for entries matching all filters. Hidden questions don't appear as dashboard cards.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .frame(width: 380, height: 520)
        .onAppear(perform: loadVocabularies)
    }

    private var activeCriteriaChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(filterStore.criteria, id: \.canonicalKey) { criterion in
                    Button {
                        filterStore.removeCriterion(criterion)
                    } label: {
                        HStack(spacing: 4) {
                            Text(criterion.displayText)
                            Image(systemName: "xmark.circle.fill").imageScale(.small)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(criterion.displayText)
                    .accessibilityHint("Removes this filter.")
                }
            }
        }
        .accessibilityIdentifier("viz-filter-chips")
    }

    private func categoryGroup(
        _ title: String,
        pairs: [(label: String, criterion: ReportFilter.FilterCriterion)]
    ) -> some View {
        DisclosureGroup {
            if pairs.isEmpty {
                Text("No values yet — file some reports first.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pairs, id: \.criterion) { pair in
                    Toggle(pair.label, isOn: Binding(
                        get: { filterStore.criteria.contains(pair.criterion) },
                        set: { active in
                            if active {
                                filterStore.addCriterion(pair.criterion)
                            } else {
                                filterStore.removeCriterion(pair.criterion)
                            }
                        }
                    ))
                }
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                let activeCount = pairs.filter { filterStore.criteria.contains($0.criterion) }.count
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("viz-filter-category-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    // Value vocabularies (from actual data) — same derivations as the iOS
    // filter sheet, fetched once when the popover appears.
    private func loadVocabularies() {
        let people = (try? modelContext.fetch(
            FetchDescriptor<PersonEntity>(sortBy: [SortDescriptor(\.text)]))) ?? []
        personNames = people.map(\.text)
        let tokens = (try? modelContext.fetch(
            FetchDescriptor<TokenEntity>(sortBy: [SortDescriptor(\.text)]))) ?? []
        tokenTexts = tokens.map(\.text)
    }

    private var placeNames: [String] {
        var names: Set<String> = []
        for report in reports {
            if let sensed = report.location?.placemark?.name, !sensed.isEmpty {
                names.insert(sensed)
            }
            for response in report.responses ?? [] {
                if let answered = response.locationResponse?.text, !answered.isEmpty {
                    names.insert(answered)
                }
            }
        }
        return names.sorted()
    }

    private var weatherConditions: [String] {
        Set(reports.compactMap(\.weather?.condition).filter { !$0.isEmpty }).sorted()
    }

    private var monthPairs: [(String, ReportFilter.FilterCriterion)] {
        let symbols = Calendar(identifier: .gregorian).monthSymbols
        return (1...12).map { (symbols[$0 - 1], .month($0)) }
    }

    private var yearPairs: [(String, ReportFilter.FilterCriterion)] {
        // Each report's OWN time zone, matching ReportFilter.matches.
        let years = Set(reports.map { report in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: report.timeZoneIdentifier) ?? .gmt
            return calendar.component(.year, from: report.date)
        })
        return years.sorted(by: >).map { (String($0), .year($0)) }
    }

    private func binding(for question: Question) -> Binding<Bool> {
        Binding(
            get: { filterStore.isVisible(question.uniqueIdentifier) },
            set: { filterStore.setVisible(question.uniqueIdentifier, $0) }
        )
    }
}
