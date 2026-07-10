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
    /// Plan 27: layout (grid vs pager) keys off the size class — NOT the
    /// idiom — so iPad Split View/Slide Over at compact width degrades to
    /// the iPhone pager automatically.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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

    /// Compact (iPhone / narrow iPad multitasking) pulls the chrome to the
    /// screen extremes like the original Reporter — the iPad grid keeps its
    /// roomier spacing.
    private var isCompact: Bool { horizontalSizeClass != .regular }

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

                // Compact collapses the inter-chrome spacing to 0 (Reporter
                // parity: chrome hugs the extremes, charts own the middle).
                VStack(spacing: isCompact ? 0 : 8) {
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
                        filterBar
                        visualizationPages
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

    /// Plan 29 parity: left-aligned "+ Filter Visualizations…" row with a
    /// hairline divider (replaces the centered pill). The report count lives
    /// on the row's trailing edge so the chart owns everything below.
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
                        // Explicit singular/plural — the ^[…](inflect:) markup only
                        // inflects when the string lands in a LocalizedStringKey,
                        // which a ternary like this silently defeats (it becomes
                        // String).
                        Text(activeCount == 0
                             ? "Filter Visualizations…"
                             : (activeCount == 1 ? "1 filter active" : "\(activeCount) filters active"))
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("viz-filter-button")

                Text("\(reports.count) reports")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityIdentifier("report-count")
            }
            .padding(.horizontal)
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(height: 0.5)
        }
        .padding(.bottom, isCompact ? 0 : 4)
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
            Group {
                if horizontalSizeClass == .regular {
                    visualizationGrid
                } else {
                    visualizationPager
                }
            }
            .task(id: visualizationTaskID) {
                rebuildVisualizations()
                // If the previously selected page's question was hidden/disabled (or this is
                // the first render), fall back to the first visible page. Leaving `selection`
                // pointed at a tag that no longer exists in the ForEach can leave the TabView
                // showing stale content instead of truly removing that page. (Harmless in the
                // grid layout — selection only matters to the pager — but kept unconditional
                // so a size-class change back to compact lands on a valid page.)
                if selectedQuestionID == nil || !visibleQuestions.contains(where: { $0.uniqueIdentifier == selectedQuestionID }) {
                    selectedQuestionID = visibleQuestions.first?.uniqueIdentifier
                }
            }
        }
    }

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
        // render in the reserved bottom strip (see `bottomBar`), so pages
        // never need dot-avoidance padding again.
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// Plan 27 (regular width): every visible question's visualization at
    /// once as a two-column card grid — an iPad-sized screen shouldn't hide
    /// N−1 visualizations behind pager swipes. Consumes the same memoized
    /// `visualizations` dictionary as the pager.
    private var visualizationGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
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
        }
        .accessibilityIdentifier("viz-grid")
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

            // Decorative centered app glyph (plan 29 parity) — matches the
            // original Reporter's non-interactive top-bar icon. Hidden from
            // VoiceOver; still queryable as an image by identifier.
            Image("HomeGlyph")
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
                .accessibilityIdentifier("home-glyph")

            Spacer()

            NavigationLink(destination: SettingsView()) {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("settings-button")
        }
        .padding(.horizontal)
        // Compact: snug under the status bar — the safe-area inset already
        // clears it, so only a hairline of breathing room is added.
        .padding(.top, isCompact ? 2 : 8)
        .padding(.bottom, isCompact ? 4 : 8)
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

    /// Plan 29: the reserved bottom strip — REPORT / plain page dots / AWAKE
    /// pill. Fixed-height sibling of the pager, so content can never overlap
    /// it (the old UIPageControl-overlay bug class is structurally gone).
    private var bottomBar: some View {
        HStack {
            Button("REPORT") {
                // Guarded for the ⌘N path: a hardware-keyboard shortcut can
                // fire while the survey is already presented (the presenting
                // view stays in the responder chain under a sheet) — don't
                // stomp an in-progress survey's request.
                guard surveyPresenter.request == nil else { return }
                surveyPresenter.request = SurveyRequest(kind: .regular, trigger: .manual)
            }
            .font(.headline)
            .foregroundStyle(.white)
            // Plan 27: new report from a hardware keyboard (iPad).
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityIdentifier("report-button")

            Spacer()

            // Dots belong to the pager only — the regular-width grid shows
            // every visualization at once, so there's nothing to page.
            if horizontalSizeClass != .regular && !visibleQuestions.isEmpty && !reports.isEmpty {
                PlainPageDots(
                    count: visibleQuestions.count,
                    currentIndex: visibleQuestions.firstIndex { $0.uniqueIdentifier == selectedQuestionID } ?? 0
                )
            }

            Spacer()

            AwakePillToggle(isAwake: awakeStore.isAwake) {
                // Toggling is authoritative even if the survey that follows is
                // cancelled — the state change reflects reality regardless of
                // whether the user files the optional report about it.
                let kind = awakeStore.toggle()
                scheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
                surveyPresenter.request = SurveyRequest(kind: kind, trigger: .manual)
            }
        }
        .padding(.horizontal)
        // The reserved strip: minHeight (not a hard frame) so accessibility
        // text sizes can grow the controls instead of clipping them. Compact
        // shrinks to the 44pt tap-target floor — the strip still bottoms out
        // at the safe-area edge, keeping the home-indicator region clean.
        .frame(minHeight: isCompact ? 44 : 52)
    }
}

/// Plan 29: plain page-indicator dots (no background pill). One read-only
/// VoiceOver element ("Page N of M") — page CHANGES stay on the adjustable
/// pager; exposing (rather than hiding) the element also keeps `page-dots`
/// reliably queryable from UI tests (PR #41 review).
private struct PlainPageDots: View {
    let count: Int
    let currentIndex: Int

    /// PR #41 review: fixed-size circles can't shrink, so a long page list
    /// would collide with the REPORT/AWAKE neighbors on 390pt phones.
    /// Tiered shrink rather than UIPageControl-style truncation (every page
    /// keeps a dot): ≤10 pages 7pt/9pt, ≤15 5pt/6pt, beyond 4pt/4pt —
    /// 15 pages ≈ 159pt, 25 pages ≈ 196pt, both inside the dots' slot.
    private var dotSize: CGFloat { count <= 10 ? 7 : (count <= 15 ? 5 : 4) }
    private var dotSpacing: CGFloat { count <= 10 ? 9 : (count <= 15 ? 6 : 4) }

    var body: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == currentIndex ? Color.white : Color.white.opacity(0.35))
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(currentIndex + 1) of \(count)")
        .accessibilityIdentifier("page-dots")
    }
}

/// Plan 29: Reporter-style AWAKE/ASLEEP pill — a capsule whose white knob
/// slides edge-to-edge as the label swaps. Semantics live in `action`;
/// this view is presentation only.
private struct AwakePillToggle: View {
    let isAwake: Bool
    let action: () -> Void

    var body: some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            HStack(spacing: 8) {
                if !isAwake { knob }
                Text(isAwake ? "AWAKE" : "ASLEEP")
                    .font(.caption.weight(.bold))
                    .kerning(0.5)
                    .foregroundStyle(.white)
                if isAwake { knob }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.18)))
        }
        .accessibilityIdentifier("awake-toggle")
        // NavigationUITests reads .label and asserts AWAKE/ASLEEP + the flip.
        .accessibilityLabel(isAwake ? "AWAKE" : "ASLEEP")
    }

    private var knob: some View {
        Circle().fill(Color.white).frame(width: 18, height: 18)
    }
}
