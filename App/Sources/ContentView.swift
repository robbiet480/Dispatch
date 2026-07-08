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

    var body: some View {
        Group {
            if onboardingCompleted {
                HomeView()
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
        // Single choke point: while locked, the survey cover's item is always nil,
        // so it can never appear simultaneously with the lock cover below. The
        // underlying request is preserved (only the setter clears it on dismiss),
        // so a request set while locked — via notification tap, cold-launch drain,
        // or StartReportIntent — presents automatically once isLocked flips false,
        // since isLocked is @Observable state read inside this getter.
        //
        // Mid-survey lock engagement (e.g. backgrounding past the grace interval
        // while a survey is in progress) tears this cover down and any in-progress
        // answers are lost. That's an accepted v1 security tradeoff (same posture
        // as most banking apps) — not a bug. Re-presentation after unlock relies on
        // `surveyPresenter.request` surviving the teardown (only the setter above
        // clears it), so the request itself is preserved even though the answers
        // captured so far are not.
        .fullScreenCover(item: Binding(
            get: { appLockStore.isLocked ? nil : surveyPresenter.request },
            set: { surveyPresenter.request = $0 })) { request in
            SurveyFlowView(kind: request.kind, trigger: request.trigger, overrideDate: request.overrideDate,
                           promptGroupID: request.promptGroupID)
        }
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
