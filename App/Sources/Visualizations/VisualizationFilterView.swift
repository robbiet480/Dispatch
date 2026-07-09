import DispatchKit
import SwiftData
import SwiftUI

/// Home's filter sheet, mirroring the original Reporter's content filters:
/// active criteria as removable chips up top, category rows (People, Places,
/// Tokens, Months, Years, Ambient Audio, Steps, Weather) drilling into value
/// pickers populated from actual data, and — a Dispatch extra — the
/// per-question show/hide toggles at the bottom. Backed by
/// `VisualizationFilterStore`; reports must match ALL active criteria.
struct VisualizationFilterView: View {
    let questions: [Question]
    let reports: [Report]
    let filterStore: VisualizationFilterStore
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var personNames: [String] = []
    @State private var tokenTexts: [String] = []

    private var theme: Theme { themeStore.theme }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.themeBackground(theme)
                    .ignoresSafeArea()

                List {
                    if !filterStore.criteria.isEmpty {
                        Section {
                            activeCriteriaChips
                                .listRowBackground(Color.clear)
                        } header: {
                            header("ACTIVE FILTERS")
                        }
                    }

                    Section {
                        categoryLink("People", values: personNames, map: { .person($0) })
                        categoryLink("Places", values: placeNames, map: { .place($0) })
                        categoryLink("Tokens", values: tokenTexts, map: { .token($0) })
                        categoryLink("Months", pairs: monthPairs)
                        categoryLink("Years", pairs: yearPairs)
                        categoryLink("Ambient Audio", pairs: ReportFilter.AudioBucket.allCases.map {
                            ($0.displayName, .ambientAudio($0))
                        })
                        categoryLink("Steps", pairs: ReportFilter.StepsBucket.allCases.map {
                            ($0.displayName, .steps($0))
                        })
                        categoryLink("Weather", values: weatherConditions, map: { .weather($0) })
                    } header: {
                        header("FILTER BY CONTENT")
                    } footer: {
                        Text("Results are only shown for entries matching all filters.")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .listRowBackground(Color.white.opacity(0.12))

                    Section {
                        ForEach(questions, id: \.uniqueIdentifier) { question in
                            Toggle(question.prompt, isOn: binding(for: question))
                                .foregroundStyle(.white)
                        }
                    } header: {
                        header("QUESTIONS")
                    } footer: {
                        Text("Hidden questions don't appear as visualization pages.")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("viz-filter-list")
            }
            .navigationTitle("Filter Visualizations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear(perform: loadVocabularies)
            .toolbar {
                if !filterStore.criteria.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear") { filterStore.clearCriteria() }
                            .tint(.white)
                            .accessibilityIdentifier("viz-filter-clear")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(.white)
                }
            }
        }
    }

    // MARK: - Active criteria chips

    /// Chips are identified by the CRITERION (kind-aware canonicalKey), not
    /// displayText — a person and a token sharing text are distinct chips
    /// and removing one can't remove the other (build-5 review fix).
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
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityIdentifier("viz-filter-chips")
    }

    // MARK: - Category rows

    private func categoryLink(_ title: String, values: [String],
                              map: @escaping (String) -> ReportFilter.FilterCriterion) -> some View {
        categoryLink(title, pairs: values.map { ($0, map($0)) })
    }

    private func categoryLink(_ title: String,
                              pairs: [(label: String, criterion: ReportFilter.FilterCriterion)]) -> some View {
        NavigationLink {
            FilterValuePickerView(title: title, pairs: pairs, filterStore: filterStore, theme: theme)
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.white)
                Spacer()
                let activeCount = pairs.filter { filterStore.criteria.contains($0.criterion) }.count
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .accessibilityIdentifier("viz-filter-category-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    // MARK: - Value vocabularies (from actual data)

    /// Fetched ONCE when the sheet appears (build-5 review fix) — these fed
    /// `body` directly before, re-querying SwiftData on every render.
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let years = Set(reports.map { calendar.component(.year, from: $0.date) })
        return years.sorted(by: >).map { (String($0), .year($0)) }
    }

    private func binding(for question: Question) -> Binding<Bool> {
        Binding(
            get: { filterStore.isVisible(question.uniqueIdentifier) },
            set: { filterStore.setVisible(question.uniqueIdentifier, $0) }
        )
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }
}

/// Drill-in value picker for one filter category: tapping a value toggles its
/// criterion in the store (checkmark when active).
private struct FilterValuePickerView: View {
    let title: String
    let pairs: [(label: String, criterion: ReportFilter.FilterCriterion)]
    let filterStore: VisualizationFilterStore
    let theme: Theme

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                if pairs.isEmpty {
                    Text("No values yet — file some reports first.")
                        .foregroundStyle(.white.opacity(0.7))
                        .listRowBackground(Color.white.opacity(0.12))
                } else {
                    ForEach(pairs, id: \.criterion) { pair in
                        Button {
                            toggle(pair.criterion)
                        } label: {
                            HStack {
                                Text(pair.label)
                                    .foregroundStyle(.white)
                                Spacer()
                                if filterStore.criteria.contains(pair.criterion) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.12))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("viz-filter-values")
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func toggle(_ criterion: ReportFilter.FilterCriterion) {
        if filterStore.criteria.contains(criterion) {
            filterStore.removeCriterion(criterion)
        } else {
            filterStore.addCriterion(criterion)
        }
    }
}
