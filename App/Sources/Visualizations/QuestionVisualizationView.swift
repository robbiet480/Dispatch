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
        VStack(alignment: .leading, spacing: 0) {
            Text(question.prompt)
                .textCase(.uppercase)
                .font(.footnote.weight(.bold))
                .kerning(1.2)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 12)
                // XCUI + VoiceOver read the label, not the rendered glyphs:
                // keep the original casing so NavigationUITests' staticTexts
                // ["Are you working?"] queries still match (plan 29).
                .accessibilityLabel(question.prompt)

            content
                .padding(.horizontal, 20)
                // Dots no longer overlay pages (plan 29 reserved strip) —
                // just breathing room above the toolbar.
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch visualization {
        case .optionShares(let shares):
            OptionSharesBarsView(shares: shares, theme: theme)
        case .numericSeries(let points, let average):
            NumericSeriesView(points: points, average: average, theme: theme)
        case .frequency(let items, let distinctCount):
            TokenFrequencyView(items: items, distinctCount: distinctCount)
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
            // Heights come from OptionBlockLayout so they always sum EXACTLY
            // to the container (PR #41 review: per-block max(share*H, 28)
            // could overflow into the bottom strip / clip in the grid card).
            let heights = OptionBlockLayout.heights(
                shares: shares.map(\.share),
                availableHeight: proxy.size.height
            )
            VStack(spacing: 2) {
                ForEach(Array(shares.enumerated()), id: \.offset) { index, entry in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tint(for: index))

                        HStack {
                            Text(entry.option)
                                .lineLimit(2)
                            Spacer()
                            Text(percentString(entry.share))
                                .lineLimit(1)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        // Blocks have data-driven heights (min 28pt) — at
                        // accessibility Dynamic Type sizes the labels must
                        // shrink rather than clip against the block.
                        .minimumScaleFactor(0.5)
                        .padding(10)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .frame(height: heights[index])
                    // One element per block: "No, 69 percent" — the visual
                    // encodes share as block height, which VoiceOver can't see.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(entry.option), \(Int((entry.share * 100).rounded())) percent")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .accessibilityIdentifier("viz-option-shares")
    }

    /// Index 0 lightens 8% off the theme background so the first block reads
    /// against it; each later block darkens 10% per index (plan 29 shading).
    /// Contrast pass (plan 29 Task 4): verified in the sim across all five
    /// themes — white labels stay legible on the lightened index-0 block,
    /// including the flagged chartreuse/gray risks (chartreuse is the low
    /// end but matches every other white-on-chartreuse home element), so
    /// the uniform no-lighten fallback was NOT needed.
    private func tint(for index: Int) -> Color {
        let base = ThemeColor.color(theme)
        return index == 0
            ? base.blended(withWhite: 0.08)
            : base.blended(withBlack: Double(index) * 0.10)
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

    /// Blends toward white by `amount` (0...1) — the index-0 block lightens
    /// off the theme background so it reads against it (plan 29).
    func blended(withWhite amount: Double) -> Color {
        guard amount > 0 else { return self }
        let resolved = UIColor(self)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let clampedAmount = min(max(amount, 0), 0.9)
        return Color(
            red: red + (1 - red) * clampedAmount,
            green: green + (1 - green) * clampedAmount,
            blue: blue + (1 - blue) * clampedAmount,
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
                // Plan 29: the average reads inline off the rule instead of
                // an external headline — full-bleed principle.
                .annotation(position: .top, alignment: .trailing) {
                    Text("AVG \(formattedAverage)")
                        .font(.caption2.weight(.semibold))
                        .kerning(0.5)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.trailing, 4)
                }
        }
        // Plan 29: no leading Y-axis gutter — the chart owns the full page
        // width; the average rule + min/max are the value anchors.
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic) {
                AxisValueLabel()
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        // Min/max captions live inside the plot's leading corners so the
        // hidden Y axis doesn't leave the sparse demo line unanchored
        // (decision recorded per plan 29 Task 5 Step 1). A flat series has
        // min == max — render one caption, not a duplicate pair (PR #41).
        .overlay(alignment: .topLeading) { cornerCaption(points.map(\.value).max()) }
        .overlay(alignment: .bottomLeading) {
            if let minValue = points.map(\.value).min(), minValue != points.map(\.value).max() {
                cornerCaption(minValue)
            }
        }
        // VoiceOver summary for the line chart (the marks themselves
        // aren't individually meaningful): count, range, latest, average.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Values over time")
        .accessibilityValue(accessibilitySummary)
        .accessibilityIdentifier("viz-numeric-series")
    }

    @ViewBuilder
    private func cornerCaption(_ value: Double?) -> some View {
        if let value {
            Text(value.truncatingRemainder(dividingBy: 1) == 0
                 ? String(format: "%.0f", value)
                 : String(format: "%.1f", value))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(4)
        }
    }

    private var formattedAverage: String {
        average.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", average)
            : String(format: "%.1f", average)
    }

    private var accessibilitySummary: String {
        guard let minValue = points.map(\.value).min(),
              let maxValue = points.map(\.value).max(),
              let latest = points.max(by: { $0.date < $1.date })?.value else {
            return "No data"
        }
        func short(_ value: Double) -> String {
            value.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", value)
                : String(format: "%.1f", value)
        }
        return "\(points.count) entries, from \(short(minValue)) to \(short(maxValue)), "
            + "latest \(short(latest)), average \(formattedAverage)"
    }
}

/// Tokens/people: the original Reporter's "N ANSWERS" layout — a large count
/// numeral over a small-caps ANSWERS label, then a comma-joined wrapping list
/// of "Token (count)" with the counts de-emphasized. Places keeps RankedRowsView.
struct TokenFrequencyView: View {
    let items: [(text: String, count: Int)]
    /// Distinct answer values across ALL answers (not capped at the top-20
    /// list) — original Reporter's "N ANSWERS" counts distinct values.
    let distinctCount: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(distinctCount)")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("viz-answer-count")
                    Text("ANSWERS")
                        .font(.caption.weight(.semibold))
                        .kerning(1.5)
                        .foregroundStyle(.white.opacity(0.7))
                }
                // "42 answers" instead of two separate elements ("42",
                // "ANSWERS") that read out of context.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(distinctCount) answers")
                joinedList
                    .font(.subheadline)
                    // The parenthesized counts read poorly ("Coding (12),") —
                    // speak "Coding, 12 times" per item instead.
                    .accessibilityLabel(spokenList)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
        }
        .accessibilityIdentifier("viz-token-frequency")
    }

    /// One wrapping Text so the comma-joined list flows naturally across
    /// lines. Built with Text interpolation (which accepts styled Text
    /// values) — `Text + Text` concatenation is deprecated as of iOS 26.
    private var joinedList: Text {
        items.enumerated().reduce(Text("")) { partial, item in
            let (index, entry) = item
            let separator = index == 0 ? Text("") : Text(", ").foregroundStyle(.white.opacity(0.6))
            let name = Text(entry.text).foregroundStyle(.white)
            let count = Text(" (\(entry.count))").font(.caption).foregroundStyle(.white.opacity(0.55))
            return Text("\(partial)\(separator)\(name)\(count)")
        }
    }

    private var spokenList: String {
        items.map { entry in
            entry.count == 1 ? "\(entry.text), once" : "\(entry.text), \(entry.count) times"
        }
        .joined(separator: "; ")
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
                    .padding(.horizontal, 20)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 4)
                    // "Home, 12 reports" as one element per ranked row.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.text), \(row.count) report\(row.count == 1 ? "" : "s")")
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
                    // Date + note text as one element, date last (the note
                    // is the content; the date is context).
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(note.text), \(note.date.formatted(date: .abbreviated, time: .omitted))")
                }
            }
        }
        .accessibilityIdentifier("viz-recent-notes")
    }
}
