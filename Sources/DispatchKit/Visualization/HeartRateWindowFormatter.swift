import Foundation

/// Renders the windowed heart-rate readings (plan 43, issue #48) as the
/// report-detail line, e.g. "72 → 88 bpm (+16) · low 64 · high 112".
/// Pure string shaping — whole-number bpm, locale-independent glyphs.
///
/// Degrades per-piece: the delta segment needs BOTH boundary readings, the
/// range segment needs BOTH min and max; either renders alone, and with
/// neither the line is nil (the row disappears — first report ever, old
/// reports, sensor off).
public enum HeartRateWindowFormatter {
    /// Reading `type` strings the range provider emits. Additive wire
    /// values — never rename (stored in Report.health and V2 exports).
    public static let startType = "heartRateWindowStart"
    public static let endType = "heartRateWindowEnd"
    public static let minType = "heartRateWindowMin"
    public static let maxType = "heartRateWindowMax"

    public static func detailLine(from readings: [HealthReading]) -> String? {
        func value(_ type: String) -> Int? {
            readings.first { $0.type == type }.map { Int($0.value.rounded()) }
        }

        var delta: String?
        if let start = value(startType), let end = value(endType) {
            let change = end - start
            let signed = change == 0 ? "±0" : String(format: "%+d", change)
            delta = "\(start) → \(end) bpm (\(signed))"
        }

        var range: String?
        if let min = value(minType), let max = value(maxType) {
            range = "low \(min) · high \(max)"
        }

        let base: String? = switch (delta, range) {
        case (let delta?, let range?): "\(delta) · \(range)"
        case (let delta?, nil): delta
        case (nil, let range?): "\(range) bpm"
        case (nil, nil): nil
        }
        guard let base else { return nil }

        // Fold in the instantaneous sensor's windowed average when present
        // (plan-43 design decision: no duplicate windowed-avg reading —
        // heartRateAvg already spans the same window). Avg ALONE is not a
        // window; it never resurrects a nil line.
        if let avg = value("heartRateAvg") {
            return "\(base) · avg \(avg)"
        }
        return base
    }
}
