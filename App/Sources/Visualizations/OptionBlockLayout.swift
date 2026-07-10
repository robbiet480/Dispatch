import Foundation

/// Height allocation for the stacked proportional option blocks (plan 29).
///
/// Pure math, kept view-free so it's unit-testable (DispatchAppTests): the
/// naive `max(share * H, minHeight)` per block can SUM past the available
/// height (e.g. shares [0.85, 0.05, 0.05, 0.05] at H=400 → 430pt), spilling
/// blocks toward the bottom strip on iPhone and clipping in the iPad grid
/// card. Instead the minimums are allocated first and only the REMAINDER is
/// distributed proportionally, so the total always equals the available
/// height exactly.
enum OptionBlockLayout {
    /// Returns one height per share. Invariant: `sum(heights) + spacing *
    /// (count - 1) == availableHeight` whenever `availableHeight` can fit the
    /// spacing at all; every height ≥ `minHeight` whenever the container can
    /// fit all minimums (otherwise it degrades to an equal split of whatever
    /// space exists — nothing to preserve proportionality with at that size).
    static func heights(
        shares: [Double],
        availableHeight: Double,
        spacing: Double = 2,
        minHeight: Double = 28
    ) -> [Double] {
        guard !shares.isEmpty else { return [] }
        let count = Double(shares.count)
        let content = max(availableHeight - spacing * (count - 1), 0)
        let minTotal = minHeight * count
        guard content > minTotal else {
            // Degenerate: container can't fit the minimums — equal split.
            return Array(repeating: content / count, count: shares.count)
        }
        let remainder = content - minTotal
        let shareSum = shares.reduce(0, +)
        guard shareSum > 0 else {
            // All-zero shares (shouldn't happen — shares come normalized):
            // equal split keeps the invariant.
            return Array(repeating: content / count, count: shares.count)
        }
        return shares.map { minHeight + remainder * ($0 / shareSum) }
    }
}
