import DispatchKit
import SwiftData
import SwiftUI

struct HomeView: View {
    @Query private var reports: [Report]
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    @Environment(ThemeStore.self) private var themeStore
    @Environment(AwakeStore.self) private var awakeStore
    @Environment(VisualizationFilterStore.self) private var filterStore
    @Environment(SurveyPresenter.self) private var surveyPresenter
    @Environment(NotificationScheduler.self) private var scheduler
    @Environment(\.notificationPrefs) private var notificationPrefs
    /// Plan 27: layout (grid vs pager) keys off the size class — NOT the
    /// idiom — so iPad Split View/Slide Over at compact width degrades to
    /// the iPhone pager automatically.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Page selection lives here (not in the shared `DashboardContentView`) so
    /// the bottom-strip page dots stay the source of truth; the pager binds to
    /// it through the shared view.
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

    /// Only the bottom-strip page dots need this (count + current index); the
    /// shared `DashboardContentView` computes its own copy for the grid/pager.
    private var visibleQuestions: [Question] {
        questions.filter { $0.isEnabled && filterStore.isVisible($0.uniqueIdentifier) }
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
                        // Shared dashboard body (Task 2.5): filter bar +
                        // grid/pager. The iOS-only survey strip stays in
                        // `bottomBar` below (SurveyPresenter never crosses into
                        // the shared view). iPhone uses the pager; the iPad
                        // passes its shipped two-column fixed grid.
                        DashboardContentView(
                            columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                            selectedQuestionID: $selectedQuestionID
                        )
                    }
                    bottomBar
                }
                // iOS 26 Safari-style toolbar depth (compact only): the chrome
                // column sinks through the bottom safe area so the strip's
                // controls sit just above the physical edge, with the home
                // indicator floating over the strip's background.
                .ignoresSafeArea(.container, edges: isCompact ? .bottom : [])
            }
            .navigationBarHidden(true)
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
        .padding(.horizontal, 20)
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
            // Sunk strip: keep a >=44pt hit target extending upward, away
            // from the home indicator (the indicator overlaps background only).
            .frame(minHeight: 44)
            .contentShape(Rectangle())
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
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 20)
        // The reserved strip: minHeight (not a hard frame) so accessibility
        // text sizes can grow the controls instead of clipping them. Compact
        // shrinks to the 44pt tap-target floor and — iOS 26 toolbar style —
        // sinks into the home-indicator zone: the dashboard column ignores the
        // bottom safe area, so this 10pt pad is measured from the physical
        // screen edge and the indicator floats over the strip's background.
        .frame(minHeight: isCompact ? 44 : 52)
        .padding(.bottom, isCompact ? 10 : 0)
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
