import DispatchKit
import SwiftUI

struct ContentView: View {
    @Environment(\.appDefaults) private var appDefaults
    @Environment(SurveyPresenter.self) private var surveyPresenter
    @State private var onboardingCompleted = false
    @State private var hasCheckedOnboarding = false

    var body: some View {
        Group {
            if onboardingCompleted {
                HomeView()
            } else {
                OnboardingView {
                    onboardingCompleted = true
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
    }
}
