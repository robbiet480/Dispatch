import Foundation

/// Single source of truth for the onboarding-completed UserDefaults key,
/// shared by DispatchApp (--skip-onboarding), ContentView, and OnboardingView.
public enum OnboardingFlag {
    public static let key = "onboarding.completed"
}
