import Charts
import DispatchKit
import SwiftUI

/// Renders a single question's aggregated visualization. One of these is shown per
/// page in Home's paged TabView, chosen by `QuestionVisualization`'s case.
struct QuestionVisualizationView: View {
    let question: Question
    let visualization: QuestionVisualization
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            Text(question.prompt)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 20)

            content
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch visualization {
        case .optionShares(let shares):
            OptionSharesBarsView(shares: shares, theme: theme)
        case .numericSeries(let points, let average):
            NumericSeriesView(points: points, average: average, theme: theme)
        case .frequency(let items):
            TokenFrequencyView(items: items)
        case .places(let items):
            RankedRowsView(rows: items.map { ($0.name, $0.count) })
        case .recentNotes(let notes):
            RecentNotesView(notes: notes)
        case .empty:
            emptyState
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No answers yet")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        }
    }
}

/// Yes/No + multiple choice: full-height proportional stacked bars, one per option,
/// each sized to its share of answered responses. Option name bottom-leading, "NN%"
/// bottom-trailing, per-index darker tint of the theme color — the marquee visual.
struct OptionSharesBarsView: View {
    let shares: [(option: String, share: Double)]
    let theme: Theme

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(shares.enumerated()), id: \.offset) { index, entry in
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(tint(for: index))

                        VStack(alignment: .leading) {
                            Spacer()
                            HStack {
                                Text(entry.option)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                Spacer()
                                Text(percentString(entry.share))
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                            }
                            .padding(10)
                        }
                    }
                    .frame(height: max(proxy.size.height * entry.share, 28))
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .accessibilityIdentifier("viz-option-shares")
    }

    private func tint(for index: Int) -> Color {
        let base = ThemeColor.color(theme)
        // Darker tint per index, like the original app's stacked-bar shading.
        let darkenAmount = Double(index) * 0.12
        return base.opacity(1.0).blended(withBlack: darkenAmount)
    }

    private func percentString(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }
}

private extension Color {
    /// Blends toward black by `amount` (0...1), used to produce per-index darker tints.
    func blended(withBlack amount: Double) -> Color {
        guard amount > 0 else { return self }
        let resolved = UIColor(self)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let clampedAmount = min(max(amount, 0), 0.9)
        return Color(
            red: red * (1 - clampedAmount),
            green: green * (1 - clampedAmount),
            blue: blue * (1 - clampedAmount),
            opacity: alpha
        )
    }
}

/// Number questions: Swift Charts line of values over time, plus the average.
struct NumericSeriesView: View {
    let points: [(date: Date, value: Double)]
    let average: Double
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Average: \(formattedAverage)")
                .font(.headline)
                .foregroundStyle(.white)

            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(.white)
                    .symbol(.circle)
                }
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .chartXAxis {
                AxisMarks(values: .automatic) {
                    AxisValueLabel()
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic) {
                    AxisValueLabel()
                        .foregroundStyle(.white.opacity(0.7))
                    AxisGridLine()
                        .foregroundStyle(.white.opacity(0.2))
                }
            }
        }
        .accessibilityIdentifier("viz-numeric-series")
    }

    private var formattedAverage: String {
        average.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", average)
            : String(format: "%.1f", average)
    }
}

/// Tokens/people: the original Reporter's "N ANSWERS" layout — a large count
/// numeral over a small-caps ANSWERS label, then a comma-joined wrapping list
/// of "Token (count)" with the counts de-emphasized. Places keeps RankedRowsView.
struct TokenFrequencyView: View {
    let items: [(text: String, count: Int)]

    private var totalAnswers: Int {
        items.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(totalAnswers)")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("viz-answer-count")
                    Text("ANSWERS")
                        .font(.caption.weight(.semibold))
                        .kerning(1.5)
                        .foregroundStyle(.white.opacity(0.7))
                }
                joinedList
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
        }
        .accessibilityIdentifier("viz-token-frequency")
    }

    /// One wrapping Text so the comma-joined list flows naturally across lines.
    private var joinedList: Text {
        items.enumerated().reduce(Text("")) { partial, item in
            let (index, entry) = item
            let separator = index == 0 ? Text("") : Text(", ").foregroundStyle(.white.opacity(0.6))
            return partial
                + separator
                + Text(entry.text).foregroundStyle(.white)
                + Text(" (\(entry.count))").font(.caption).foregroundStyle(.white.opacity(0.55))
        }
    }
}

/// Places: ranked rows, text left, count right.
struct RankedRowsView: View {
    let rows: [(text: String, count: Int)]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.text)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(row.count)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 4)
                }
            }
        }
        .accessibilityIdentifier("viz-ranked-rows")
    }
}

/// Note questions: newest-first date + text rows.
struct RecentNotesView: View {
    let notes: [(date: Date, text: String)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                        Text(note.text)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .accessibilityIdentifier("viz-recent-notes")
    }
}
