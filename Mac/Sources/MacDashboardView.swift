import DispatchKit
import SwiftData
import SwiftUI

/// The Mac dashboard — the iPad grid (plan 27/29) as the detail pane's
/// default content: every visible question's visualization at once in an
/// adaptive card grid, fed by the kit's `VisualizationData` through the same
/// memoized rebuild pattern (`visualizationTaskID`) as HomeView. Window
/// resizes reflow the adaptive grid for free.
struct MacDashboardView: View {
    @Query private var reports: [Report]
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    @Query private var people: [PersonEntity]
    @Environment(ThemeStore.self) private var themeStore
    @Environment(VisualizationFilterStore.self) private var filterStore

    /// The sidebar's search query (owned by MacRootView): the dashboard's
    /// charts must aggregate the same search-filtered report set the sidebar
    /// list and stat tiles show, not all-reports totals.
    var searchQuery: String = ""

    @State private var visualizations: [String: QuestionVisualization] = [:]
    @State private var isShowingFilter = false

    private var theme: Theme { themeStore.theme }

    private var searchedReports: [Report] {
        ReportSearch.filter(reports, query: searchQuery)
    }

    private var visibleQuestions: [Question] {
        questions.filter { $0.isEnabled && filterStore.isVisible($0.uniqueIdentifier) }
    }

    /// HomeView's rebuild key, verbatim: report count + newest date +
    /// identity fingerprint + visible questions + filter criteria + person
    /// registry fingerprint. See HomeView.visualizationTaskID for the full
    /// rationale (XOR identity fingerprint catches same-count delete+backfill).
    private var visualizationTaskID: String {
        let newestDate = reports.map(\.date).max()?.timeIntervalSinceReferenceDate ?? 0
        let identityFingerprint = reports.reduce(into: 0) { partial, report in
            partial ^= report.uniqueIdentifier.hashValue
        }
        let visibleIDs = visibleQuestions.map(\.uniqueIdentifier).sorted().joined(separator: ",")
        let criteria = filterStore.criteria.map(\.canonicalKey).joined(separator: ",")
        let peopleFingerprint = people.reduce(into: 0) { partial, person in
            var hasher = Hasher()
            hasher.combine(person.uniqueIdentifier)
            hasher.combine(person.text)
            hasher.combine(person.alternateNames)
            partial ^= hasher.finalize()
        }
        return "\(reports.count)|\(newestDate)|\(identityFingerprint)|\(visibleIDs)|\(criteria)|\(peopleFingerprint)|\(searchQuery)"
    }

    private func filteredReports() -> [Report] {
        let searched = searchedReports
        let criteria = filterStore.criteria
        guard !criteria.isEmpty else { return searched }
        let peopleQuestionIDs = Set(questions.filter { $0.type == .people }.map(\.uniqueIdentifier))
        return searched.filter {
            ReportFilter.matches(report: $0, criteria: criteria,
                                 peopleQuestionIDs: peopleQuestionIDs, people: people)
        }
    }

    private func rebuildVisualizations() {
        let matching = filteredReports()
        var next: [String: QuestionVisualization] = [:]
        for question in visibleQuestions {
            next[question.uniqueIdentifier] = VisualizationData.build(for: question, reports: matching,
                                                                      people: people)
        }
        if next != visualizations {
            visualizations = next
        }
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            if reports.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    filterBar
                    visualizationGrid
                }
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

    private var filterBar: some View {
        let activeCount = filterStore.criteria.count
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    isShowingFilter = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.square")
                            .font(.subheadline)
                        Text(activeCount == 0
                             ? "Filter Visualizations…"
                             : (activeCount == 1 ? "1 filter active" : "\(activeCount) filters active"))
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("viz-filter-button")
                .popover(isPresented: $isShowingFilter, arrowEdge: .bottom) {
                    MacFilterPopover(
                        questions: questions.filter(\.isEnabled),
                        reports: reports,
                        filterStore: filterStore
                    )
                }

                Spacer()

                Text("\(searchedReports.count) reports")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityIdentifier("report-count")
            }
            .padding(.horizontal, 20)
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(height: 0.5)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var visualizationGrid: some View {
        if visibleQuestions.isEmpty {
            Spacer()
            Text("No visualizations to show")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)],
                          spacing: 16) {
                    ForEach(visibleQuestions, id: \.uniqueIdentifier) { question in
                        QuestionVisualizationView(
                            question: question,
                            visualization: visualizations[question.uniqueIdentifier] ?? .empty,
                            theme: theme
                        )
                        .frame(height: 340)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .accessibilityIdentifier("viz-grid")
            .task(id: visualizationTaskID) {
                rebuildVisualizations()
            }
        }
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
