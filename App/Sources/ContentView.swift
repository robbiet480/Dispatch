import DispatchKit
import SwiftUI

struct ContentView: View {
    @Environment(\.appDefaults) private var appDefaults
    @Environment(SurveyPresenter.self) private var surveyPresenter
    @Environment(NotificationScheduler.self) private var notificationScheduler
    @State private var onboardingCompleted = false
    @State private var hasCheckedOnboarding = false

    var body: some View {
        Group {
            if onboardingCompleted {
                HomeView()
            } else {
                OnboardingView {
                    onboardingCompleted = true
                    notificationScheduler.requestPermissionIfNeeded()
                }
            }
        }
        .onAppear {
            guard !hasCheckedOnboarding else { return }
            hasCheckedOnboarding = true
            onboardingCompleted = appDefaults.bool(forKey: OnboardingFlag.key)
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
    }
}
