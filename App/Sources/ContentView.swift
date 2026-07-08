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
        .fullScreenCover(item: Binding(
            get: { surveyPresenter.request },
            set: { surveyPresenter.request = $0 })) { request in
            SurveyFlowView(kind: request.kind, trigger: request.trigger)
        }
        .onChange(of: notificationScheduler.pendingSurveyRequest) { _, newValue in
            guard let newValue else { return }
            surveyPresenter.request = newValue
            notificationScheduler.pendingSurveyRequest = nil
        }
        .fullScreenCover(isPresented: Binding(
            get: { appLockStore.isLocked },
            set: { appLockStore.isLocked = $0 })) {
            AppLockView()
        }
    }
}
