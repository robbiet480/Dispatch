import DispatchKit
import SwiftData
import SwiftUI

/// The Insights screen: honest, on-device correlations across ALL reports
/// (`InsightsEngine.compute`), rendered as cards with sample-count captions.
///
/// DECISION (logged in the engine too): insights deliberately ignore the home
/// screen's visualization content filters — computing correlations over a
/// filtered subset invites spurious conclusions from tiny samples, which the
/// engine's guards exist to prevent.
struct InsightsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Query private var reports: [Report]
    @Query private var questions: [Question]

    /// nil = not yet computed (first appearance); [] = computed, nothing
    /// passed the honesty guards.
    @State private var insights: [Insight]?

    private var theme: Theme { themeStore.theme }

    /// Recompute trigger (HomeView.visualizationTaskID pattern): count +
    /// newest date + identity fingerprint. Unrelated re-renders don't refire
    /// the compute; adds, deletes, and backfills do. In-place edits to an
    /// existing report's responses change none of these components, so they
    /// only take effect on the next add/delete or screen re-entry.
    private var insightsTaskID: String {
        let newestDate = reports.map(\.date).max()?.timeIntervalSinceReferenceDate ?? 0
        let identityFingerprint = reports.reduce(into: 0) { partial, report in
            partial ^= report.uniqueIdentifier.hashValue
        }
        return "\(reports.count)|\(newestDate)|\(identityFingerprint)|\(questions.count)"
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
                            ForEach(Array(insights.enumerated()), id: \.offset) { _, insight in
                                insightCard(insight)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .accessibilityIdentifier("insights-view")
        // Memoized compute: the engine is a pure, fast in-memory pass, and
        // @Model instances aren't Sendable, so it runs in this non-blocking
        // .task rather than a detached actor hop — same trade HomeView makes
        // for its visualizations.
        .task(id: insightsTaskID) {
            insights = InsightsEngine.compute(reports: reports, questions: questions)
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

    /// Two honest empty states: with substantial data (≥ 20 filed reports —
    /// the engine's overall minimum) the guards genuinely found nothing, so
    /// say that; with less data, the two-weeks explanation applies.
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
