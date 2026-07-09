import CoreMotion
import DispatchKit
import Foundation
import os

private let pedometerLog = Logger(subsystem: "io.robbie.Dispatch", category: "pedometer")

/// CMPedometer access for the flights-DESCENDED count (HealthKit has
/// flightsClimbed but no descended equivalent — original Reporter's
/// "7 STAIRCASES UP · 2 DOWN" needs Core Motion). Strictly optional
/// enrichment: any unavailability (no barometer hardware, Motion permission
/// denied/restricted/undetermined, query error, nil floorsDescended)
/// degrades to nil and the flights reading stays climbed-only with
/// unchanged display.
enum PedometerReader {
    static func floorsDescended(from start: Date, to end: Date) async -> Double? {
        guard CMPedometer.isFloorCountingAvailable() else { return nil }
        switch CMPedometer.authorizationStatus() {
        case .authorized:
            break
        default:
            // Includes `.notDetermined`: querying while undetermined would
            // fire the Motion permission dialog mid-capture. The dialog is
            // OWNED by PermissionCascade.requestMotion (sequenced, awaited);
            // no capture path may ever ambush the user with it. Until the
            // cascade has run, the reading simply degrades to climbed-only.
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
