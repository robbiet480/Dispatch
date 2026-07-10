import DispatchKit
import SwiftData
import SwiftUI

struct HomeView: View {
    @Query private var reports: [Report]
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    /// Person registry (plan 22): people visualizations/filters resolve
    /// alternate names through it.
    @Query private var people: [PersonEntity]
    @Environment(ThemeStore.self) private var themeStore
    @Environment(AwakeStore.self) private var awakeStore
    @Environment(VisualizationFilterStore.self) private var filterStore
    @Environment(SurveyPresenter.self) private var surveyPresenter
    @Environment(NotificationScheduler.self) private var scheduler
    @Environment(\.notificationPrefs) private var notificationPrefs
    @Environment(AppLockStore.self) private var appLockStore
    @State private var isShowingFilter = false
    @State private var visualizations: [String: QuestionVisualization] = [:]
    @State private var selectedQuestionID: String?

    /// Plan 27: when embedded as the detail-column root of the iPad
    /// `NavigationSplitView` (see `RootNavigationView`), the surrounding
    /// stack belongs to the split view's detail column — rendering our own
    /// `NavigationStack` there would nest stacks and break pushes.
    var isEmbedded: Bool = false
    /// Plan 27: on iPad the reports button toggles the split view's sidebar
    /// (same `reports-list-button` identifier) instead of pushing the list.
    var toggleSidebar: (() -> Void)? = nil

    private var theme: Theme { themeStore.theme }

    private var visibleQuestions: [Question] {
        questions.filter { $0.isEnabled && filterStore.isVisible($0.uniqueIdentifier) }
    }

    /// Combines everything that should trigger a visualization rebuild: report count, the
    /// newest report's date (catches edits/new reports without per-field diffing), a
    /// report-identity fingerprint, and the set of currently visible question ids (covers
    /// both filter toggles and enable/disable changes). Unrelated re-renders (theme, awake
    /// toggle) don't change this key, so `.task(id:)` won't refire and the cached
    /// visualizations stay put.
    ///
    /// The report-identity fingerprint (XOR of each report's `uniqueIdentifier` hash) exists
    /// because count + newest-date alone can't distinguish "delete report A, backfill report
    /// B at the same newest date" from a no-op: count and newest date can both stay identical
    /// across such a delete+backfill, which would leave the memo stale and skip the rebuild.
    /// XOR (rather than a sorted/concatenated hash) keeps this order-independent and O(n) with
    /// no allocation, which is all we need since it's just a change-detection fingerprint, not
    /// a stable identifier.
    private var visualizationTaskID: String {
        let newestDate = reports.map(\.date).max()?.timeIntervalSinceReferenceDate ?? 0
        let identityFingerprint = reports.reduce(into: 0) { partial, report in
            partial ^= report.uniqueIdentifier.hashValue
        }
        let visibleIDs = visibleQuestions.map(\.uniqueIdentifier).sorted().joined(separator: ",")
        // canonicalKey, not displayText: kind-aware, so swapping a person
        // filter for a same-named token filter still changes the memo key.
        let criteria = filterStore.criteria.map(\.canonicalKey).joined(separator: ",")
        // Person registry fingerprint (plan 22): renames/merges change how
        // people visualizations aggregate, so they must refire the rebuild.
        let peopleFingerprint = people.reduce(into: 0) { partial, person in
            // Hash each person as ONE combined unit — XORing the field
            // hashes separately would let two people swapping alternates
            // (or a rename mirrored by an alias change) cancel out.
            var hasher = Hasher()
            hasher.combine(person.uniqueIdentifier)
            hasher.combine(person.text)
            hasher.combine(person.alternateNames)
            partial ^= hasher.finalize()
        }
        return "\(reports.count)|\(newestDate)|\(identityFingerprint)|\(visibleIDs)|\(criteria)|\(peopleFingerprint)"
    }

    /// Content-filtered reports feeding the viz pages. Only computed inside
    /// `rebuildVisualizations()` (the memoized `.task(id:)` path) — never per frame.
    private func filteredReports() -> [Report] {
        let criteria = filterStore.criteria
        guard !criteria.isEmpty else { return reports }
        let peopleQuestionIDs = Set(questions.filter { $0.type == .people }.map(\.uniqueIdentifier))
        return reports.filter {
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
        // Only replace values that actually changed so QuestionVisualizationView identity/diffing
        // (via Equatable QuestionVisualization) stays cheap for unaffected pages.
        if next != visualizations {
            visualizations = next
        }
    }

    var body: some View {
        if isEmbedded {
            dashboard
        } else {
            NavigationStack {
                dashboard
            }
        }
    }

    private var dashboard: some View {
            ZStack {
                Color.themeBackground(theme)
                    .ignoresSafeArea()

                VStack {
                    topBar
                    if reports.isEmpty {
                        Spacer()
                        hexagon
                        Text("\(reports.count) reports")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .accessibilityIdentifier("report-count")
                        Spacer()
                    } else {
                        filterPill
                        visualizationPages
                        Text("\(reports.count) reports")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .accessibilityIdentifier("report-count")
                    }
                    bottomBar
                }
            }
            .navigationBarHidden(true)
            // Gated on the lock, mirroring ContentView's survey-cover pattern: if the
            // lock engages while this sheet is up, the getter flips to false so the
            // sheet dismisses and the lock's fullScreenCover in ContentView can present
            // without this sheet blocking it.
            .sheet(isPresented: Binding(
                get: { isShowingFilter && !appLockStore.isLocked },
                set: { isShowingFilter = $0 })) {
                VisualizationFilterView(
                    questions: questions.filter(\.isEnabled),
                    reports: reports,
                    filterStore: filterStore
                )
            }
    }

    private var filterPill: some View {
        let activeCount = filterStore.criteria.count
        return Button {
            isShowingFilter = true
        } label: {
            // Explicit singular/plural — the ^[…](inflect:) markup only
            // inflects when the string lands in a LocalizedStringKey, which
            // a ternary like this silently defeats (it becomes String).
            Text(activeCount == 0
                 ? "Filter Visualizations…"
                 : (activeCount == 1 ? "1 filter active" : "\(activeCount) filters active"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.15))
                .clipShape(Capsule())
        }
        .accessibilityIdentifier("viz-filter-button")
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var visualizationPages: some View {
        if visibleQuestions.isEmpty {
            Spacer()
            Text("No visualizations to show")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        } else {
            TabView(selection: $selectedQuestionID) {
                ForEach(visibleQuestions, id: \.uniqueIdentifier) { question in
                    QuestionVisualizationView(
                        question: question,
                        visualization: visualizations[question.uniqueIdentifier] ?? .empty,
                        theme: theme
                    )
                    .tag(Optional(question.uniqueIdentifier))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .task(id: visualizationTaskID) {
                rebuildVisualizations()
                // If the previously selected page's question was hidden/disabled (or this is
                // the first render), fall back to the first visible page. Leaving `selection`
                // pointed at a tag that no longer exists in the ForEach can leave the TabView
                // showing stale content instead of truly removing that page.
                if selectedQuestionID == nil || !visibleQuestions.contains(where: { $0.uniqueIdentifier == selectedQuestionID }) {
                    selectedQuestionID = visibleQuestions.first?.uniqueIdentifier
                }
            }
        }
    }

    private var topBar: some View {
        HStack {
            // Same identifier either way — "show me the reports list" just
            // means "toggle the sidebar" inside the iPad split view.
            if let toggleSidebar {
                Button(action: toggleSidebar) {
                    Image(systemName: "list.bullet")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("reports-list-button")
            } else {
                NavigationLink(destination: ReportsListView()) {
                    Image(systemName: "list.bullet")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("reports-list-button")
            }

            Spacer()

            NavigationLink(destination: SettingsView()) {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("settings-button")
        }
        .padding()
    }

    @ViewBuilder
    private var hexagon: some View {
        if reports.isEmpty {
            NavigationLink(destination: QuestionSettingsView()) {
                ZStack {
                    Image(systemName: "hexagon.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("Edit your questions")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
            }
            .accessibilityIdentifier("home-hexagon")
        } else {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 96))
                .foregroundStyle(.white.opacity(0.35))
                .accessibilityIdentifier("home-hexagon")
        }
    }

    private var bottomBar: some View {
        HStack {
            Button("REPORT") {
                surveyPresenter.request = SurveyRequest(kind: .regular, trigger: .manual)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .accessibilityIdentifier("report-button")

            Spacer()

            Button(awakeStore.isAwake ? "AWAKE" : "ASLEEP") {
                // Toggling is authoritative even if the survey that follows is
                // cancelled — the state change reflects reality regardless of
                // whether the user files the optional report about it.
                let kind = awakeStore.toggle()
                scheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
                surveyPresenter.request = SurveyRequest(kind: kind, trigger: .manual)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .accessibilityIdentifier("awake-toggle")
        }
        .padding()
    }
}
