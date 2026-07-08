import DispatchKit
import SwiftUI

struct OnboardingPage: Identifiable {
    let id = UUID()
    let theme: Theme
    let headline: String
    let body: String
}

struct OnboardingView: View {
    let onDone: () -> Void

    @Environment(\.appDefaults) private var appDefaults
    @State private var selection = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            theme: .teal,
            headline: "Snapshot your life.",
            body: "Dispatch checks in with you at random moments throughout the day, not on a fixed schedule. That randomness matters: it captures what you're actually doing instead of what you'd plan to report if you knew a survey was coming."
        ),
        OnboardingPage(
            theme: .pink,
            headline: "Control your data.",
            body: "Everything you record stays on your device by default. Nothing leaves unless you explicitly turn on sync or export it yourself, so your reports stay private until you decide otherwise."
        ),
        OnboardingPage(
            theme: .chartreuse,
            headline: "Embrace your sensors.",
            body: "Grant access to things like location, health, and photos, and Dispatch will quietly attach that context to each report. The more permissions you allow, the richer and more automatic your reports become."
        ),
        OnboardingPage(
            theme: .gray,
            headline: "Make it yours.",
            body: "The questions you're asked aren't fixed. Add, remove, or reorder them any time so Dispatch only ever asks about the things you actually care about tracking."
        )
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            if selection == pages.count - 1 {
                Button("DONE") {
                    appDefaults.set(true, forKey: OnboardingFlag.key)
                    onDone()
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding()
                .accessibilityIdentifier("onboarding-done")
                .padding(.bottom, 32)
            }
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        ZStack {
            Color.themeBackground(page.theme)
                .ignoresSafeArea()

            TriangleMotif()
                .fill(.white.opacity(0.08))
                .frame(width: 260, height: 260)
                .offset(y: -180)

            VStack(spacing: 16) {
                Spacer()
                Text(page.headline)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(page.body)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
                Spacer()
            }
        }
    }
}

private struct TriangleMotif: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
