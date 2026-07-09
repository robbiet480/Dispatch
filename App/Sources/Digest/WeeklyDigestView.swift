import DispatchKit
import SwiftData
import SwiftUI

/// The Weekly Digest screen: a stats header computed kit-side
/// (`DigestStats.compute`) plus a short narrative — on-device language model
/// when available, deterministic template otherwise. Generation is async and
/// on-demand (screen open / Regenerate); nothing runs in the background.
struct WeeklyDigestView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Query private var reports: [Report]
    @Query private var questions: [Question]

    @State private var stats: DigestStats?
    @State private var narrative = ""
    @State private var source: DigestNarrativeSource?
    @State private var isGenerating = false
    @State private var generationTask: Task<Void, Never>?

    private var theme: Theme { themeStore.theme }
    private var isTestEnvironment: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--mock-sensors") || arguments.contains("--ui-testing")
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let stats {
                        statsHeader(stats)
                        topLists(stats)
                        numericAverages(stats)
                        narrativeSection
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Weekly Digest")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .accessibilityIdentifier("weekly-digest-view")
        .onAppear {
            guard stats == nil else { return }
            let computed = DigestStats.compute(reports: reports, questions: questions,
                                               weekEnding: Date())
            stats = computed
            regenerate(with: computed)
        }
        .onDisappear { generationTask?.cancel() }
    }

    // MARK: - Stats header

    private func statsHeader(_ stats: DigestStats) -> some View {
        HStack(spacing: 12) {
            statTile(value: "\(stats.reportCount)", caption: "REPORTS", detail: deltaText(stats))
            statTile(value: "\(stats.streakDays)", caption: "DAY STREAK", detail: nil)
            if stats.stepsTotal > 0 {
                statTile(value: "\(Int(stats.stepsTotal))", caption: "STEPS", detail: nil)
            }
            if stats.workoutCount > 0 {
                statTile(value: "\(stats.workoutCount)", caption: "WORKOUTS", detail: nil)
            }
        }
    }

    private func deltaText(_ stats: DigestStats) -> String? {
        let delta = stats.reportCount - stats.priorWeekReportCount
        if delta > 0 { return "+\(delta) vs last week" }
        if delta < 0 { return "\(delta) vs last week" }
        return "same as last week"
    }

    private func statTile(value: String, caption: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(caption)
                .font(.caption2.weight(.semibold))
                .kerning(1)
                .foregroundStyle(.white.opacity(0.7))
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Top lists

    @ViewBuilder
    private func topLists(_ stats: DigestStats) -> some View {
        rankedRow(title: "TOP ANSWERS", items: stats.topTokens)
        rankedRow(title: "PEOPLE", items: stats.topPeople)
        rankedRow(title: "PLACES", items: stats.topPlaces)
    }

    @ViewBuilder
    private func rankedRow(title: String, items: [DigestStats.RankedItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .kerning(1.5)
                    .foregroundStyle(.white.opacity(0.7))
                Text(items.map { "\($0.text) (\($0.count))" }.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private func numericAverages(_ stats: DigestStats) -> some View {
        if !stats.numericAverages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("AVERAGES")
                    .font(.caption.weight(.semibold))
                    .kerning(1.5)
                    .foregroundStyle(.white.opacity(0.7))
                ForEach(stats.numericAverages, id: \.prompt) { average in
                    HStack {
                        Text(average.prompt)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Spacer()
                        Text(String(format: "%.1f", average.average))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
        }
    }

    // MARK: - Narrative

    private var narrativeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("THIS WEEK")
                    .font(.caption.weight(.semibold))
                    .kerning(1.5)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if isGenerating {
                    ProgressView()
                        .tint(.white)
                } else {
                    Button {
                        guard let stats else { return }
                        regenerate(with: stats)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .accessibilityIdentifier("digest-regenerate")
                }
            }
            Text(narrative)
                .font(.body)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("digest-narrative")
            if source == .template {
                Text("Summary generated without Apple Intelligence.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func regenerate(with stats: DigestStats) {
        generationTask?.cancel()
        isGenerating = true
        narrative = ""
        source = nil
        let testEnvironment = isTestEnvironment
        generationTask = Task {
            let result = await DigestGenerator.narrative(
                for: stats, isTestEnvironment: testEnvironment
            ) { partial in
                narrative = partial
            }
            guard !Task.isCancelled else { return }
            narrative = result.text
            source = result.source
            isGenerating = false
        }
    }
}
