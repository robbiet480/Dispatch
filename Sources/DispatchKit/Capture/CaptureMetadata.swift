import Foundation

/// Capture-time context metadata (plan 44, #61): zero-permission device
/// state plus Motion & Fitness readings, stored as FLAT optional fields on
/// the report (never as their own sensors — owner design decision on
/// PR #72). Assembled app-side at capture time, gated by the Sensors-screen
/// `deviceContext` / `motionFitness` toggles; every field degrades to nil
/// when its toggle is off, its platform lacks the API, or (motion family)
/// the OS authorization isn't already granted.
public struct CaptureMetadata: Equatable, Sendable {
    // Device Context (zero-permission).
    public var isLowPowerMode: Bool?
    /// 0...1, normalized via `CaptureMetadataFormatting.normalizedBrightness`.
    public var screenBrightness: Double?
    /// "light" or "dark".
    public var interfaceStyle: String?
    /// Normalized audio output route (e.g. "Speaker", "Headphones",
    /// "BluetoothA2DP") via `CaptureMetadataFormatting.audioRouteLabel`.
    public var audioOutputRoute: String?

    // Motion & Fitness (existing OS authorization; never prompts at capture).
    /// "stationary"/"walking"/"running"/"cycling"/"automotive"/"unknown".
    public var motionActivity: String?
    /// Barometric pressure in kilopascals (CMAltitudeData.pressure unit).
    public var barometricPressureKPa: Double?

    public init() {}
}

/// Pure validity/normalization helpers for the metadata fields — kit-level
/// and TDD-able; the app-side readers stay thin.
public enum CaptureMetadataFormatting {
    /// Clamps a raw UIScreen brightness into 0...1; non-finite degrades to nil.
    public static func normalizedBrightness(_ raw: Double) -> Double? {
        guard raw.isFinite else { return nil }
        return min(max(raw, 0), 1)
    }

    /// Collapses CMMotionActivity's overlapping booleans into one label.
    /// Priority: automotive > cycling > running > walking > stationary —
    /// the most specific/fastest mode wins when the classifier reports
    /// several. Falls back to "unknown" when only the unknown flag is set,
    /// nil when nothing is (no classification at all).
    public static func motionActivityLabel(stationary: Bool, walking: Bool, running: Bool,
                                           cycling: Bool, automotive: Bool,
                                           unknown: Bool) -> String? {
        if automotive { return "automotive" }
        if cycling { return "cycling" }
        if running { return "running" }
        if walking { return "walking" }
        if stationary { return "stationary" }
        if unknown { return "unknown" }
        return nil
    }

    /// Normalizes an AVAudioSession.Port raw value for storage — strips the
    /// redundant trailing "Output" some port types carry
    /// ("BluetoothA2DPOutput" → "BluetoothA2DP"); already-clean values
    /// ("Speaker", "Headphones") pass through unchanged.
    public static func audioRouteLabel(portType raw: String) -> String {
        guard raw.hasSuffix("Output"), raw != "Output" else { return raw }
        return String(raw.dropLast("Output".count))
    }

    /// Positive, finite kilopascal readings only; anything else degrades to
    /// nil (same degrade-through-absence rule as MotionFormatting).
    public static func validPressureKPa(_ raw: Double) -> Double? {
        guard raw.isFinite, raw > 0 else { return nil }
        return raw
    }
}
