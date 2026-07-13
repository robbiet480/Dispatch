import DispatchKit
import SwiftData
import SwiftUI

/// Per-question correlation drill-in (plan 34): every context dimension gets
/// a row — a finding with its interval and sample count, an explicit
/// "no reliable link", or an explicit "not enough data". Absence of a claim
/// is itself information, so nothing is silently hidden, and the standing
/// correlation-≠-causation disclaimer always renders.
struct QuestionCorrelationView: View {
    let questionID: String
    let prompt: String

    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query private var reports: [Report]
    @Query private var questions: [Question]
    @Query private var people: [PersonEntity]

    /// nil = not yet computed; a non-nil wrapper with a nil payload means the
    /// question fell below the eligibility gate since navigation.
    @State private var result: QuestionCorrelations??

    private var theme: Theme { themeStore.theme }

    /// Memoized compute trigger — the InsightsView fingerprint recipe.
    private var correlationTaskID: String {
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
        return "\(questionID)|\(reports.count)|\(newestDate)|\(identityFingerprint)|\(questions.count)|\(peopleFingerprint)"
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if case .some(let computed) = result {
                        if let computed {
                            content(computed)
                        } else {
                            ineligibleNotice
                        }
                    }
                    // The correlation-≠-causation disclaimer is an
                    // unconditional part of the drill-in — it renders even
                    // during the initial compute (result == nil) so the
                    // "always present" contract holds through load, not only
                    // after findings arrive.
                    disclaimer
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                // Plan 27: readable column on iPad; no-op at iPhone widths.
                .readableColumn()
            }
        }
        .navigationTitle(prompt)
        .inlineNavTitleOnPhone()
        .darkNavBarOnPhone()
        .accessibilityIdentifier("question-correlations-view")
        .task(id: correlationTaskID) {
            result = .some(CorrelationEngine.compute(questionID: questionID,
                                                     reports: reports,
                                                     questions: questions,
                                                     people: people))
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func content(_ computed: QuestionCorrelations) -> some View {
        ForEach(Array(computed.targets.enumerated()), id: \.offset) { _, target in
            targetSection(target, computed: computed)
        }
        if computed.isTruncated {
            Text("Showing your \(CorrelationEngine.maximumTargets) most common answers.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    @ViewBuilder
    private func targetSection(_ target: TargetCorrelations,
                               computed: QuestionCorrelations) -> some View {
        // yesNo/number questions have exactly one target; multi-answer
        // questions group rows under each answer's label.
        if computed.targets.count > 1 || target.label != computed.prompt {
            Text(target.label.uppercased())
                .font(.caption.weight(.semibold))
                .kerning(0.5)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 4)
        }
        LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 12) {
            ForEach(Array(target.rows.enumerated()), id: \.offset) { _, row in
                rowCard(row, targetLabel: target.label, prompt: computed.prompt)
            }
        }
    }

    @ViewBuilder
    private func rowCard(_ row: CorrelationRow, targetLabel: String,
                         prompt: String) -> some View {
        switch row.outcome {
        case .finding(let finding):
            findingCard(finding, row: row, targetLabel: targetLabel, prompt: prompt)
        case .noReliableLink(let sampleCount):
            mutedRow(title: row.dimension.displayLabel,
                     message: "No reliable link — tested across \(sampleCount) reports",
                     identifier: "correlation-null-row")
        case .insufficientData(let have, let needed):
            mutedRow(title: row.dimension.displayLabel,
                     message: "Not enough data yet (have \(have), needs \(needed))",
                     identifier: "correlation-insufficient-row")
        }
    }

    private func findingCard(_ finding: CorrelationFinding, row: CorrelationRow,
                             targetLabel: String, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.dimension.displayLabel.uppercased())
                .font(.caption2.weight(.semibold))
                .kerning(0.5)
                .foregroundStyle(.white.opacity(0.55))
            Text(finding.headline(targetLabel: targetLabel, prompt: prompt,
                                  dimension: row.dimension))
                .font(.headline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(finding.detail(targetLabel: targetLabel, dimension: row.dimension))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(finding.tier.rawValue) · \(finding.sampleCount) reports")
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
        .accessibilityIdentifier("correlation-finding-card")
    }

    private func mutedRow(title: String, message: String,
                          identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .kerning(0.5)
                .foregroundStyle(.white.opacity(0.4))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var ineligibleNotice: some View {
        Text("This question no longer has enough answered reports for correlations — they unlock at \(CorrelationEngine.minimumEligibleAnswers) answers.")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Standing correlation-≠-causation copy — always part of the scroll
    /// content, never conditional on findings.
    private var disclaimer: some View {
        Text(CorrelationEngine.causationDisclaimer)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            .accessibilityIdentifier("correlation-disclaimer")
    }

    /// Plan 27: adaptive card columns on regular width; compact stays one
    /// flexible column.
    private var cardColumns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: 320), spacing: 12)]
        }
        return [GridItem(.flexible())]
    }
}
