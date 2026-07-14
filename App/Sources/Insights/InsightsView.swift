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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Task 3.8: suppresses this view's own title when hosted in
    /// `LargeScreenShell`, where the pane picker is the sole title.
    @Environment(\.isInLargeScreenShell) private var inShell
    @Query private var reports: [Report]
    @Query private var questions: [Question]
    /// Person registry (plan 22): person signals resolve alternate names.
    @Query private var people: [PersonEntity]

    /// nil = not yet computed (first appearance); [] = computed, nothing
    /// passed the honesty guards.
    @State private var insights: [Insight]?
    /// Plan 34: questions eligible for the per-question correlation
    /// drill-in, recomputed in the same task. nil = not yet computed.
    @State private var correlationQuestions: [(id: String, prompt: String,
                                               answeredCount: Int)]?

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
        // Person registry fingerprint (plan 22): renames/merges change how
        // person signals aggregate, so they must refire the compute.
        let peopleFingerprint = people.reduce(into: 0) { partial, person in
            // Hash each person as ONE combined unit — XORing the field
            // hashes separately would let two people swapping alternates
            // (or a rename mirrored by an alias change) cancel out.
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
                            // Plan 27: adaptive columns on regular width
                            // (iPad); a single flexible column at compact
                            // width renders identically to the old VStack.
                            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 12) {
                                ForEach(Array(insights.enumerated()), id: \.offset) { _, insight in
                                    insightCard(insight)
                                }
                            }
                        }
                        // Plan 34: per-question correlations are independent
                        // of the top-8 feed — either can be populated while
                        // the other is empty.
                        correlationsSection
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(inShell ? "" : "Insights")
        .inlineNavTitleOnPhone()
        .darkNavBarOnPhone()
        .accessibilityIdentifier("insights-view")
        // Memoized compute: the engine is a pure, fast in-memory pass, and
        // @Model instances aren't Sendable, so it runs in this non-blocking
        // .task rather than a detached actor hop — same trade HomeView makes
        // for its visualizations.
        .task(id: insightsTaskID) {
            insights = InsightsEngine.compute(reports: reports, questions: questions,
                                              people: people)
            // Plan 34: the drill-in list shares the fingerprint — report
            // count/newest/identity + question count + people already cover
            // its inputs.
            // Engine returns eligible IDs WITH their answered counts from a
            // single pass — no per-question re-scan of every report, and the
            // caption count is exactly the count that decided eligibility.
            let byID = Dictionary(questions.map { ($0.uniqueIdentifier, $0) },
                                  uniquingKeysWith: { first, _ in first })
            correlationQuestions = CorrelationEngine
                .eligibleQuestions(reports: reports, questions: questions)
                .compactMap { entry in
                    guard let question = byID[entry.id] else { return nil }
                    return (id: entry.id, prompt: question.prompt,
                            answeredCount: entry.count)
                }
        }
    }

    /// Plan 34: CORRELATIONS drill-in list. Hidden entirely when no question
    /// clears the eligibility gate — a one-line unlock footnote renders
    /// instead so the feature is discoverable.
    @ViewBuilder
    private var correlationsSection: some View {
        if let correlationQuestions {
            if correlationQuestions.isEmpty {
                Text("Per-question correlations unlock at \(CorrelationEngine.minimumEligibleAnswers) answers to a question.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    // Polish batch: centered so the hint sits under the
                    // (centered) empty state rather than hugging the left edge
                    // of a full-width pane.
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("correlations-unlock-footnote")
            } else {
                Text("Correlations")
                    .font(.caption.weight(.semibold))
                    .kerning(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 8)
                VStack(spacing: 8) {
                    ForEach(correlationQuestions, id: \.id) { entry in
                        NavigationLink {
                            QuestionCorrelationView(questionID: entry.id,
                                                    prompt: entry.prompt)
                        } label: {
                            correlationRow(entry)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("correlation-question-row")
                    }
                }
            }
        }
    }

    private func correlationRow(_ entry: (id: String, prompt: String,
                                          answeredCount: Int)) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.prompt)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(entry.answeredCount) answers")
                    .font(.caption2.weight(.semibold))
                    .kerning(0.5)
                    .foregroundStyle(.white.opacity(0.55))
                    .textCase(.uppercase)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    /// Plan 27: adaptive card columns on regular width; compact stays one
    /// flexible column (identical to the previous VStack rendering).
    private var cardColumns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: 320), spacing: 12)]
        }
        return [GridItem(.flexible())]
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

    /// Polish batch: a TEACHING empty state. The honest "No insights yet"
    /// message is kept as a centered lead-in, then a short header and three
    /// EXAMPLE cards illustrate what Insights surfaces once there's enough
    /// data — so a fresh install shows a helpful preview instead of a bare
    /// sea of themed color. The whole block is centered (`readableColumn`
    /// caps then re-centers) rather than hugging the left edge of the pane.
    private var emptyState: some View {
        VStack(spacing: 20) {
            // Honest lead-in (keeps the real `insights-empty-state` id).
            VStack(spacing: 8) {
                Text("No insights yet")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(emptyStateMessage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("insights-empty-state")

            // Teaching preview: clearly-labeled example cards.
            VStack(spacing: 12) {
                Text("Here's what you'll see once you have more data")
                    .font(.caption.weight(.semibold))
                    .kerning(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                ForEach(Self.exampleInsights, id: \.title) { example in
                    exampleCard(title: example.title, detail: example.detail)
                }
            }
        }
        // Plan 27: readable column on iPad; no-op at iPhone widths. Also
        // re-centers the block in the full-width Insights pane.
        .readableColumn()
    }

    /// Illustrative examples for the teaching empty state — NOT real results.
    /// Deliberately plain tuples (never `Insight`s) so they can't leak into
    /// the real feed, and the cards below carry a distinct id.
    private static let exampleInsights: [(title: String, detail: String)] = [
        (title: "Reports mentioning 'gym' average more steps",
         detail: "Days you wrote about the gym tended to come with a higher step count."),
        (title: "Your mood peaks on weekends",
         detail: "Weekend reports leaned toward better moods than weekdays."),
        (title: "Higher focus on days you logged coffee",
         detail: "Focus ratings ran a little higher on days a coffee was logged.")
    ]

    /// An example card: same shape/typography as `insightCard` but visually
    /// dimmed, dash-bordered, and badged "Example" so it never reads as a real
    /// insight. Carries `insight-card-example`, NOT the real `insight-card` id,
    /// so UI tests that count real cards don't pick these up.
    private func exampleCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Example")
                .font(.caption2.weight(.semibold))
                .kerning(0.5)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.5))
            Text(title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.15),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insight-card-example")
    }
}
