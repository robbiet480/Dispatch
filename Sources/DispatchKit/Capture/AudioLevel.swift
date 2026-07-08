import Foundation

/// Converts raw AVAudioRecorder dBFS (−160…0) to the original Reporter
/// display scale: display = (raw + 65) × 2 (gist.github.com/dbreunig/9315705).
public enum AudioLevel {
    public static func displayValue(fromRaw raw: Double) -> Double {
        (raw + 65) * 2
    }

    public static func label(forDisplay display: Double) -> String {
        switch display {
        case ..<30: "EXTREMELY QUIET"
        case ..<50: "QUIET"
        case ..<70: "MODERATE"
        case ..<90: "LOUD"
        default: "EXTREMELY LOUD"
        }
    }
}
