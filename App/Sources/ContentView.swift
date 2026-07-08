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
        .fullScreenCover(item: Binding(
            get: { appLockStore.isLocked ? nil : surveyPresenter.request },
            set: { surveyPresenter.request = $0 })) { request in
            SurveyFlowView(kind: request.kind, trigger: request.trigger, overrideDate: request.overrideDate)
        }
        .fullScreenCover(isPresented: Binding(
            get: { appLockStore.isLocked },
            set: { appLockStore.isLocked = $0 })) {
            AppLockView()
        }
    }
}
