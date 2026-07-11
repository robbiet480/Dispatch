import Foundation

/// One surfaced correlation, presentation-ready from the kit: the view and the
/// digest render these sentences verbatim. Deliberately a value type with no
/// schema/model footprint — insights are recomputed on demand, never persisted.
///
/// Language contract (the honesty guards are the feature): titles and details
/// speak in "tends to" / "average" terms and never make causal claims — the
/// engine reports associations, not explanations.
public struct Insight: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// Difference of means: a categorical split against a numeric signal
        /// ("Reports where you mention “gym” average 2,400 more steps").
        case categoricalNumeric
        /// Co-occurrence rates: a context signal against an answer signal
        /// ("You answer Yes to “Working?” on 84% of reports at Office").
        case cooccurrence
    }

    /// Headline sentence, e.g. "Reports where you see Angela tend to run
    /// higher in mood valence."
    public var title: String
    /// Supporting sentence with both sides of the comparison, e.g.
    /// "Average 8,400 steps vs 6,000 otherwise."
    public var detail: String
    public var kind: Kind
    /// Normalized effect in [0, 1] — the ranking key, not a test statistic.
    public var strength: Double
    /// Reports the comparison was computed over (both sides of the split).
    public var sampleCount: Int
    /// The source keys of the two signals this insight compares (e.g.
    /// `question:<id>` × `place:<key>`). Identity for dedupe: two insights
    /// sharing a source key restate the same underlying signal — the digest's
    /// two-sentence summary skips the weaker one so a question never
    /// contributes two near-identical sentences.
    public var sourceKeys: Set<String>

    public init(title: String, detail: String, kind: Kind,
                strength: Double, sampleCount: Int,
                sourceKeys: Set<String> = []) {
        self.title = title
        self.detail = detail
        self.kind = kind
        self.strength = strength
        self.sampleCount = sampleCount
        self.sourceKeys = sourceKeys
    }
}
