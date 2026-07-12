import AVFAudio
import CoreMotion
import DispatchKit
import UIKit

/// Assembles the capture-time context metadata (plan 44, #61): zero-permission
/// device state plus Motion & Fitness readings, gated by the Sensors-screen
/// `deviceContext` / `motionFitness` toggles. Not a SensorProvider — no
/// checklist row, no CaptureCoordinator outcome; the fields land as flat
/// payload metadata via ReportBuilder.
///
/// Authorization rule (the PedometerReader rule): the motion reads NEVER
/// trigger a fresh permission dialog at capture time. The Motion & Fitness
/// dialog is owned by PermissionCascade; until it has run (or if denied),
/// the motion fields simply stay nil.
enum CaptureMetadataReader {
    static func read(settings: SensorSettings) async -> CaptureMetadata {
        var metadata = CaptureMetadata()
        if settings.isEnabled(.deviceContext) {
            let device = await deviceState()
            metadata.isLowPowerMode = device.isLowPowerMode
            metadata.screenBrightness = device.screenBrightness
            metadata.interfaceStyle = device.interfaceStyle
            metadata.audioOutputRoute = device.audioOutputRoute
        }
        if settings.isEnabled(.motionFitness) {
            metadata.motionActivity = await MotionActivityReader.current()
            metadata.barometricPressureKPa = await BarometerReader.pressureKPa()
        }
        return metadata
    }

    /// Synchronous UIKit/AVFAudio state, read on the main actor.
    @MainActor
    private static func deviceState() -> CaptureMetadata {
        var device = CaptureMetadata()
        device.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        device.screenBrightness = scene.flatMap {
            CaptureMetadataFormatting.normalizedBrightness($0.screen.brightness)
        }
        device.interfaceStyle =
            UITraitCollection.current.userInterfaceStyle == .dark ? "dark" : "light"
        device.audioOutputRoute = AVAudioSession.sharedInstance().currentRoute.outputs.first
            .map { CaptureMetadataFormatting.audioRouteLabel(portType: $0.portType.rawValue) }
        return device
    }
}

/// Current motion activity from CMMotionActivityManager — the most recent
/// classification in the last 30 minutes, collapsed to one label via
/// CaptureMetadataFormatting. Follows PedometerReader's exact patterns:
/// availability check, authorization check that never prompts, and a
/// OneShotResumeGuard against the CoreMotion completion-handler double-fire
/// trap (observed on iOS 27 beta — see PedometerReader/PermissionCascade).
enum MotionActivityReader {
    static func current() async -> String? {
        guard CMMotionActivityManager.isActivityAvailable() else { return nil }
        guard CMMotionActivityManager.authorizationStatus() == .authorized else { return nil }
        let manager = CMMotionActivityManager()
        let gate = OneShotResumeGuard()
        // Plain continuation, PedometerReader-style: CoreMotion always calls
        // the handler back (with an error at minimum), so no cancellation
        // handler is needed — and the one-shot gate absorbs double-fires.
        return await withCheckedContinuation { continuation in
            let now = Date()
            manager.queryActivityStarting(from: now.addingTimeInterval(-30 * 60),
                                          to: now, to: .main) { activities, _ in
                let label = activities?.last.flatMap {
                    CaptureMetadataFormatting.motionActivityLabel(
                        stationary: $0.stationary, walking: $0.walking,
                        running: $0.running, cycling: $0.cycling,
                        automotive: $0.automotive, unknown: $0.unknown)
                }
                if gate.claim() { continuation.resume(returning: label) }
            }
        }
    }
}

/// One barometric pressure sample from CMAltimeter. Pressure only exists on
/// RELATIVE altitude updates (CMAltitudeData.pressure, kPa) — the absolute
/// altimeter's CMAbsoluteAltitudeData carries no pressure field, so
/// isAbsoluteAltitudeAvailable alone doesn't help here and only the relative
/// check gates. Same never-prompt authorization rule as the activity reader.
enum BarometerReader {
    static func pressureKPa() async -> Double? {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return nil }
        guard CMAltimeter.authorizationStatus() == .authorized else { return nil }
        let altimeter = CMAltimeter()
        let gate = OneShotResumeGuard()
        return await withCheckedContinuation { continuation in
            altimeter.startRelativeAltitudeUpdates(to: .main) { data, _ in
                altimeter.stopRelativeAltitudeUpdates()
                let kPa = data.flatMap {
                    CaptureMetadataFormatting.validPressureKPa($0.pressure.doubleValue)
                }
                if gate.claim() { continuation.resume(returning: kPa) }
            }
        }
    }
}
