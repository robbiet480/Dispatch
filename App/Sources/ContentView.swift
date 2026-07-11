import DispatchKit
import SwiftUI

struct ContentView: View {
    @Environment(\.appDefaults) private var appDefaults
    @Environment(\.notificationPrefs) private var notificationPrefs
    @Environment(SurveyPresenter.self) private var surveyPresenter
    @Environment(NotificationScheduler.self) private var notificationScheduler
    @Environment(AwakeStore.self) private var awakeStore
    @Environment(AppLockStore.self) private var appLockStore
    @State private var onboardingCompleted = false
    @State private var hasCheckedOnboarding = false
    /// Tracks whether the Weekly Digest sheet is actually on screen (its
    /// onAppear/onDisappear), for the REVERSE presentation handoff below —
    /// binding state alone can't distinguish "dismissing" from "gone".
    @State private var isDigestSheetPresented = false

    var body: some View {
        Group {
            if onboardingCompleted {
                RootNavigationView()
            } else {
                OnboardingView {
                    onboardingCompleted = true
                    notificationScheduler.requestPermissionIfNeeded(prefs: notificationPrefs, awakeStore: awakeStore)
                }
            }
        }
        .onAppear {
            guard !hasCheckedOnboarding else { return }
            hasCheckedOnboarding = true
            onboardingCompleted = appDefaults.bool(forKey: OnboardingFlag.key)
        }
        .task {
            // Drain any pending survey request set before this view's
            // onChange handler registered — a notification tap that
            // cold-launches the app can set `pendingSurveyRequest` before
            // SwiftUI wires up observation, so onChange alone would miss it.
            guard let pending = notificationScheduler.pendingSurveyRequest else { return }
            surveyPresenter.request = pending
            notificationScheduler.pendingSurveyRequest = nil
        }
        .onChange(of: notificationScheduler.pendingSurveyRequest) { _, newValue in
            guard let newValue else { return }
            surveyPresenter.request = newValue
            notificationScheduler.pendingSurveyRequest = nil
        }
        // Digest notification tap → present the Weekly Digest sheet. Gated
        // on the lock like every other presentation: while locked, the
        // getter yields false and the flag survives until unlock.
        //
        // Serialized against the survey cover (plan 16 debt item): this view
        // sources BOTH presentations, and SwiftUI drops the second of two
        // simultaneous ones. The survey wins — it's the time-sensitive
        // capture; the digest can wait. While a survey request is pending or
        // presented, this getter yields false and the digest flag survives
        // (only the dismiss setter clears it), so the sheet presents
        // automatically once the survey cover goes down — both getters read
        // @Observable state, so the handoff re-evaluates on its own.
        .sheet(isPresented: Binding(
            get: {
                notificationScheduler.pendingDigestPeriod != nil && !appLockStore.isLocked
                    && surveyPresenter.request == nil
            },
            set: { if !$0 { notificationScheduler.pendingDigestPeriod = nil } })) {
            NavigationStack {
                WeeklyDigestView(period: notificationScheduler.pendingDigestPeriod ?? .week)
            }
            .onAppear { isDigestSheetPresented = true }
            .onDisappear { isDigestSheetPresented = false }
        }
        // Single choke point: while locked, the survey cover's item is always nil,
        // so it can never appear simultaneously with the lock cover below. The
        // underlying request is preserved (only the setter clears it on dismiss),
        // so a request set while locked — via notification tap, cold-launch drain,
        // or FileReportIntent — presents automatically once isLocked flips false,
        // since isLocked is @Observable state read inside this getter.
        //
        // Mid-survey lock engagement (e.g. backgrounding past the grace interval
        // while a survey is in progress) tears this cover down and any in-progress
        // answers are lost. That's an accepted v1 security tradeoff (same posture
        // as most banking apps) — not a bug. Re-presentation after unlock relies on
        // `surveyPresenter.request` surviving the teardown (only the setter above
        // clears it), so the request itself is preserved even though the answers
        // captured so far are not.
        // REVERSE-order handoff (build-13 review minor, the mirror of the
        // digest-waits-for-survey case above): a survey request arriving
        // WHILE the digest sheet is up flips the sheet's getter false (the
        // sheet starts dismissing), but presenting this cover in the same
        // pass — mid-dismissal, same presentation source — is exactly the
        // simultaneous-presentation case SwiftUI drops. Gate on the sheet
        // being fully off screen: `isDigestSheetPresented` is @State, so its
        // onDisappear flip re-evaluates this getter and the cover presents
        // itself once the sheet is gone. The digest flag survives (only the
        // sheet's dismiss setter clears it), so the digest re-presents after
        // the survey — neither presentation is ever lost, in either order.
        // Plan 27: same serialized binding and content either way — only the
        // presentation container differs by idiom. iPhone keeps the full-bleed
        // cover; iPad presents the survey as a centered sheet (system form
        // sheet) with interactive dismissal disabled so CANCEL + the discard
        // confirmation remain the only exit, matching fullScreenCover
        // semantics.
        .modifier(SurveyPresentationModifier(request: Binding(
            get: {
                appLockStore.isLocked || isDigestSheetPresented ? nil : surveyPresenter.request
            },
            set: { surveyPresenter.request = $0 })))
        // NOTE: the lock surface itself now lives in a dedicated UIWindow
        // (`PrivacyCoverWindow`, driven from DispatchApp's scenePhase handler)
        // at `.alert + 1`, so it always wins over any SwiftUI presentation
        // state in this tree and appears synchronously before the
        // app-switcher snapshot. The `isLocked` gating of the survey cover
        // above (and of ReportsListView's backfill sheet and HomeView's
        // visualization filter sheet) stays: while locked, presentations are
        // suppressed and re-present automatically once isLocked flips false.
    }
}

/// Plan 27: idiom-gated survey presentation. The binding (with all its
/// lock/digest serialization semantics) is constructed by ContentView and
/// shared by both branches; the idiom is constant for the app's lifetime, so
/// the branch never flips mid-presentation.
private struct SurveyPresentationModifier: ViewModifier {
    let request: Binding<SurveyRequest?>

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.sheet(item: request) { request in
                surveyFlow(request)
                    // A drag-to-dismiss would silently discard in-flight
                    // answers without the confirmation alert — keep CANCEL
                    // as the only exit, like the iPhone cover.
                    .interactiveDismissDisabled()
            }
        } else {
            content.fullScreenCover(item: request) { request in
                surveyFlow(request)
            }
        }
    }

    private func surveyFlow(_ request: SurveyRequest) -> some View {
        SurveyFlowView(kind: request.kind, trigger: request.trigger, overrideDate: request.overrideDate,
                       promptGroupID: request.promptGroupID,
                       triggeringWorkoutID: request.triggeringWorkoutID)
    }
}
