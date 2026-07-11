import DispatchKit
import SwiftData
import SwiftUI

/// Mac twin of the iOS InsightsView: honest on-device correlations across
/// ALL reports (`InsightsEngine.compute`) in an adaptive card grid. Insights
/// deliberately ignore the dashboard's content filters — correlations over a
/// filtered subset invite spurious conclusions from tiny samples (the
/// engine's guards exist to prevent exactly that).
struct MacInsightsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Query private var reports: [Report]
    @Query private var questions: [Question]
    @Query private var people: [PersonEntity]

    /// nil = not yet computed; [] = computed, nothing passed the guards.
    @State private var insights: [Insight]?

    private var theme: Theme { themeStore.theme }

    /// Same recompute trigger as the iOS view (count + newest date +
    /// identity fingerprint + question count + person registry fingerprint).
    private var insightsTaskID: String {
        let newestDate = reports.map(\.date).max()?.timeIntervalSinceReferenceDate ?? 0
        let identityFingerprint = reports.reduce(into: 0) { partial, report in
            partial ^= report.uniqueIdentifier.hashValue
        }
        let peopleFingerprint = people.reduce(into: 0) { partial, person in
            var hasher = Hasher()
            hasher.combine(person.uniqueIdentifier)
            hasher.combine(person.text)
            hasher.combine(person.alternateNames)
            partial ^= hasher.finalize()
        }
        return "\(reports.count)|\(newestDate)|\(identityFingerprint)|\(questions.count)|\(peopleFingerprint)"
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let insights {
                        if insights.isEmpty {
                            emptyState
                        } else {
                            explainer
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)],
                                      alignment: .leading, spacing: 12) {
                                ForEach(Array(insights.enumerated()), id: \.offset) { _, insight in
                                    insightCard(insight)
                                }
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Insights")
        .accessibilityIdentifier("insights-view")
        .task(id: insightsTaskID) {
            insights = InsightsEngine.compute(reports: reports, questions: questions,
                                              people: people)
        }
    }

    private var filedCount: Int {
        reports.filter { !$0.isDraft }.count
    }

    private var explainer: some View {
        Text("Patterns across all \(filedCount) of your reports. These are tendencies, not causes — small or noisy differences stay hidden.")
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.7))
            .padding(.bottom, 4)
    }

    private func insightCard(_ insight: Insight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(insight.title)
                .font(.headline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(insight.detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Text("Based on \(insight.sampleCount) reports")
                .font(.caption2.weight(.semibold))
                .kerning(0.5)
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insight-card")
    }

    private var emptyStateMessage: String {
        if filedCount >= 20 {
            return "No pattern is strong or steady enough to show yet — that's the honest answer. Across your \(filedCount) reports, nothing cleared the sample-size and effect-size guards. Keep filing; steady patterns surface here as they emerge."
        }
        return "Insights look for steady patterns across your reports — like which answers tend to come with more steps or a better mood. They need around two weeks of regular reports before anything is solid enough to show. Keep filing and check back."
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No insights yet")
                .font(.headline)
                .foregroundStyle(.white)
            Text(emptyStateMessage)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insights-empty-state")
    }
}
