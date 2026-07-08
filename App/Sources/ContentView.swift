import DispatchKit
import SwiftUI

struct ContentView: View {
    @State private var onboardingCompleted = UserDefaults.standard.bool(forKey: "onboarding.completed")

    var body: some View {
        if onboardingCompleted {
            HomeView()
        } else {
            OnboardingView {
                onboardingCompleted = true
            }
        }
    }
}
