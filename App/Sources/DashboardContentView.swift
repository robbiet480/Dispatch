import DispatchKit
import SwiftData
import SwiftUI

/// Task 2.5: the populated dashboard body shared by the iOS `HomeView`
/// (iPhone pager + iPad grid) and the Mac `.dashboard` pane (via
/// `MacDashboardView`). Both platforms already drew every visualization from
/// the dual-target `QuestionVisualizationView`; the divergence was the
/// surrounding chrome. This owns the pieces that were genuinely identical —
/// the memoized visualization rebuild, the filter bar (with `report-count`),
/// and the visualization grid — while the parts that legitimately diverge stay
/// behind `#if os` here or with the callers:
///
/// - The iOS-only REPORT/AWAKE survey strip (and `SurveyPresenter`, which is
///   an iOS-app-target type) stays entirely in `HomeView`.
/// - The Mac filter surface (`MacFilterPopover`) and the sidebar `searchQuery`
///   integration are preserved behind `#if os(macOS)` / a parameter.
/// - The two empty states (iOS interactive hexagon vs. Mac iCloud-sync note)
///   stay with their callers; this view assumes a non-empty report set.
struct DashboardContentView: View {
    @Query private var reports: [Report]
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    /// Person registry (plan 22): people visualizations/filters resolve
    /// alternate names through it.
    @Query private var people: [PersonEntity]
    @Environment(ThemeStore.self) private var themeStore
    @Environment(VisualizationFilterStore.self) private var filterStore

    /// The Mac sidebar's search query (owned by `MacRootView`): the dashboard's
    /// charts must aggregate the same search-filtered report set the sidebar
    /// list and stat tiles show, not all-reports totals. iOS passes "" — and an
    /// empty query matches every report (`ReportSearch.matches`), so the search
    /// layer is a no-op on iOS and `report-count` stays `reports.count` there.
    var searchQuery: String = ""

    /// Grid columns: the iPad passes the shipped two-column fixed grid, the Mac
    /// passes the adaptive grid (reflows on window resize). The iOS-compact
    /// (iPhone) layout ignores this and uses the pager instead.
    var columns: [GridItem]

    /// Page selection for the iOS compact pager. Owned by `HomeView` so its
    /// bottom-strip page dots stay in sync; the Mac passes `.constant(nil)`
    /// (grid only — no pager, no dots).
    @Binding var selectedQuestionID: String?

    @State private var visualizations: [String: QuestionVisualization] = [:]
    @State private var isShowingFilter = false

    #if os(iOS)
    /// Plan 27: layout (grid vs pager) keys off the size class — NOT the idiom —
    /// so iPad Split View/Slide Over at compact width degrades to the iPhone
    /// pager automatically.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Gates the filter sheet against the app lock (mirrors HomeView's old
    /// survey-cover pattern), iOS-only.
    @Environment(AppLockStore.self) private var appLockStore
    #endif

    private var theme: Theme { themeStore.theme }

    #if os(iOS)
    /// Compact (iPhone / narrow iPad multitasking) collapses inter-chrome
    /// spacing to 0, matching HomeView's dashboard column so the shared body
    /// slots in without shifting the topBar/bottomBar gaps.
    private var isCompact: Bool { horizontalSizeClass != .regular }
    #endif

    /// The inter-child spacing of this view's VStack. Kept equal to HomeView's
    /// dashboard VStack spacing on iOS so nesting the filter bar + pages one
    /// level deeper preserves every gap; the Mac used a flat spacing of 8.
    private var pagesSpacing: CGFloat {
        #if os(iOS)
        return isCompact ? 0 : 8
        #else
        return 8
        #endif
    }

    /// Search-scoped reports (Mac sidebar search; iOS no-op). `report-count`
    /// reads its `.count`.
    private var searchedReports: [Report] {
        ReportSearch.filter(reports, query: searchQuery)
    }

    private var visibleQuestions: [Question] {
        questions.filter { $0.isEnabled && filterStore.isVisible($0.uniqueIdentifier) }
    }

    /// Combines everything that should trigger a visualization rebuild: report count, the
    /// newest report's date (catches edits/new reports without per-field diffing), a
    /// report-identity fingerprint, the set of currently visible question ids (covers both
    /// filter toggles and enable/disable changes), the filter criteria, the person registry
    /// fingerprint, and (Mac) the search query. Unrelated re-renders (theme, awake toggle)
    /// don't change this key, so `.task(id:)` won't refire and the cached visualizations
    /// stay put.
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
        // searchQuery drives the rebuild wherever a reports-sidebar search is
        // wired: macOS, and iPad (the shell threads its sidebar search here).
        // On iPhone HomeView passes no search, so it stays "". Keep it in the
        // key regardless.
        return "\(reports.count)|\(newestDate)|\(identityFingerprint)|\(visibleIDs)|\(criteria)|\(peopleFingerprint)|\(searchQuery)"
    }

    /// Content-filtered reports feeding the viz pages. Only computed inside
    /// `rebuildVisualizations()` (the memoized `.task(id:)` path) — never per frame.
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
        // Only replace values that actually changed so QuestionVisualizationView identity/diffing
        // (via Equatable QuestionVisualization) stays cheap for unaffected pages.
        if next != visualizations {
            visualizations = next
        }
    }

    var body: some View {
        VStack(spacing: pagesSpacing) {
            filterBar
            visualizationPages
        }
        #if os(iOS)
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
        #endif
    }

    /// Plan 29 parity: left-aligned "+ Filter Visualizations…" row with a
    /// hairline divider. The report count lives on the row's trailing edge so
    /// the chart owns everything below. iOS opens a sheet; the Mac opens
    /// `MacFilterPopover` anchored to the button.
    private var filterBar: some View {
        let activeCount = filterStore.criteria.count
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                filterButton(activeCount: activeCount)

                #if os(macOS)
                Spacer()
                #endif

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
        #if os(iOS)
        .padding(.bottom, isCompact ? 0 : 4)
        #else
        .padding(.top, 8)
        #endif
    }

    private func filterButton(activeCount: Int) -> some View {
        // Explicit singular/plural — the ^[…](inflect:) markup only inflects
        // when the string lands in a LocalizedStringKey, which a ternary like
        // this silently defeats (it becomes String).
        let label = HStack(spacing: 8) {
            Image(systemName: "plus.square")
                .font(.subheadline)
            Text(activeCount == 0
                 ? "Filter Visualizations…"
                 : (activeCount == 1 ? "1 filter active" : "\(activeCount) filters active"))
                .font(.caption)
                .fontWeight(.semibold)
        }
        .foregroundStyle(.white.opacity(0.7))

        #if os(macOS)
        return Button {
            isShowingFilter = true
        } label: {
            label.contentShape(Rectangle())
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
        #else
        return Button {
            isShowingFilter = true
        } label: {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("viz-filter-button")
        #endif
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
            pagesContent
                .task(id: visualizationTaskID) {
                    rebuildVisualizations()
                    #if os(iOS)
                    // If the previously selected page's question was hidden/disabled (or this is
                    // the first render), fall back to the first visible page. Leaving `selection`
                    // pointed at a tag that no longer exists in the ForEach can leave the TabView
                    // showing stale content instead of truly removing that page. (Harmless in the
                    // grid layout — selection only matters to the pager — but kept unconditional
                    // so a size-class change back to compact lands on a valid page.)
                    if selectedQuestionID == nil || !visibleQuestions.contains(where: { $0.uniqueIdentifier == selectedQuestionID }) {
                        selectedQuestionID = visibleQuestions.first?.uniqueIdentifier
                    }
                    #endif
                }
        }
    }

    @ViewBuilder
    private var pagesContent: some View {
        #if os(iOS)
        // Plan 27 (regular width): the two-column card grid — an iPad-sized
        // screen shouldn't hide N−1 visualizations behind pager swipes.
        if horizontalSizeClass == .regular {
            visualizationGrid
        } else {
            visualizationPager
        }
        #else
        visualizationGrid
        #endif
    }

    /// Every visible question's visualization at once as a card grid. Consumes
    /// the memoized `visualizations` dictionary; columns come from the caller
    /// (iPad two-column fixed / Mac adaptive).
    private var visualizationGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
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
            #if os(macOS)
            // The Mac has no bottom survey strip below the grid, so pad the
            // scroll content off the window's bottom edge.
            .padding(.bottom)
            #endif
        }
        .accessibilityIdentifier("viz-grid")
    }

    #if os(iOS)
    private var visualizationPager: some View {
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
        // Plan 29: the UIPageControl overlay is off entirely — plain dots
        // render in the reserved bottom strip (see HomeView.bottomBar), so
        // pages never need dot-avoidance padding again.
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
    #endif
}
