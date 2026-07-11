import Foundation

public enum SensorPayload: Sendable {
    case location(LocationSnapshot)
    case weather(WeatherObservation)
    case altitude(Double)
    case photos(count: Int, records: [PhotoRecord])
    case audio(AudioSample)
    case battery(Double)
    case connection(Int)
    case focus(FocusState)
    case health([HealthReading])
    case media(MediaSample)
    /// Meters/second, degrees, degrees respectively (plan 43, #61) — raw
    /// values, formatted per units preference at display time like every
    /// other sensor.
    case speed(Double)
    case course(Double)
    case heading(Double)
}

public enum SensorOutcome: Sendable {
    case captured(SensorPayload)
    case unavailable(reason: String)
    case disabled
}

/// One capturable context source. Implementations wrap a system framework
/// (CoreLocation, HealthKit, …) or a mock. capture() may take seconds; the
/// coordinator enforces the timeout.
public protocol SensorProvider: Sendable {
    var kind: SensorKind { get }
    func capture() async throws -> SensorPayload
}

public struct CaptureEvent: Sendable {
    public let kind: SensorKind
    public let outcome: SensorOutcome
    public init(kind: SensorKind, outcome: SensorOutcome) {
        self.kind = kind
        self.outcome = outcome
    }
}
