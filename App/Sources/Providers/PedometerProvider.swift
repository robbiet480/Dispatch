import CoreMotion
import DispatchKit
import Foundation
import os

private let pedometerLog = Logger(subsystem: "io.robbie.Dispatch", category: "pedometer")

/// CMPedometer access for the flights-DESCENDED count (HealthKit has
/// flightsClimbed but no descended equivalent — original Reporter's
/// "7 STAIRCASES UP · 2 DOWN" needs Core Motion). Strictly optional
/// enrichment: any unavailability (no barometer hardware, Motion permission
/// denied/restricted, query error, nil floorsDescended) degrades to nil and
/// the flights reading stays climbed-only with unchanged display.
enum PedometerReader {
    static func floorsDescended(from start: Date, to end: Date) async -> Double? {
        guard CMPedometer.isFloorCountingAvailable() else { return nil }
        switch CMPedometer.authorizationStatus() {
        case .denied, .restricted:
            return nil
        case .notDetermined, .authorized:
            break
        @unknown default:
            return nil
        }
        let pedometer = CMPedometer()
        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, error in
                if let error {
                    pedometerLog.info("pedometer query failed (degrading to climbed-only): \(error, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data?.floorsDescended?.doubleValue)
            }
        }
    }
}
