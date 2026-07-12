import AVFAudio
import CoreLocation
import CoreMotion
import DispatchKit
import Foundation
import HealthKit
import Intents
import MediaPlayer
import Photos

/// The individually requestable permissions backing the sensor rows —
/// one case per system dialog the cascade sequences (notifications and
/// contacts are surfaced elsewhere: notifications in Notification settings,
/// contacts via its own toggle in Sensors). Medications deliberately have
/// no case: iOS 26 per-object read authorization
/// (`requestPerObjectReadAuthorization`) exposes no status API, so there is
/// no REAL state to render — the medications dialog remains reachable only
/// through the full cascade.
enum SensorPermission: String, CaseIterable {
    case location
    case health
    case motion
    case microphone
    case photos
    case mediaLibrary
    case focus
}

/// Real authorization state, straight from each framework's status API.
///
/// `requested` is HealthKit-specific honesty: Apple deliberately hides
/// READ-grant status (an app cannot distinguish granted from denied reads),
/// so the truthful post-request state is "the dialog has been shown", not
/// "Granted" — `getRequestStatusForAuthorization` is the only real signal
/// and it only distinguishes should-request from unnecessary.
enum SensorPermissionState: String {
    case granted
    case requested
    case notDetermined
    case denied
    case unknown
}

/// Reads the CURRENT authorization state for each permission from the
/// owning framework — never cached, never guessed. In the test environment
/// no framework is touched; states come from the
/// `SENSOR_PERMISSION_STATUSES` launch-environment JSON
/// (`{"location":"granted","photos":"denied", ...}`), defaulting to
/// `.unknown` (no affordance rendered) so existing UI tests see an
/// unchanged screen.
@MainActor
struct SensorPermissionStatusProvider {
    let isTestEnvironment: Bool

    func status(for permission: SensorPermission) async -> SensorPermissionState {
        if isTestEnvironment {
            return stubbedStatus(for: permission)
        }
        switch permission {
        case .location:
            return switch CLLocationManager().authorizationStatus {
            case .notDetermined: .notDetermined
            case .restricted, .denied: .denied
            case .authorizedAlways, .authorizedWhenInUse: .granted
            @unknown default: .unknown
            }
        case .health:
            guard HKHealthStore.isHealthDataAvailable() else { return .unknown }
            // Read-status is intentionally opaque in HealthKit — see
            // SensorPermissionState.requested. NEVER add the medication
            // types to this read set (uncatchable NSException — see
            // HealthKitReader.readTypes).
            let status: HKAuthorizationRequestStatus? = await withCheckedContinuation { continuation in
                HKHealthStore().getRequestStatusForAuthorization(
                    toShare: [], read: HealthKitReader.readTypes
                ) { status, error in
                    continuation.resume(returning: error == nil ? status : nil)
                }
            }
            return switch status {
            case .shouldRequest: .notDetermined
            case .unnecessary: .requested
            default: .unknown
            }
        case .motion:
            guard CMPedometer.isFloorCountingAvailable() else { return .unknown }
            return switch CMPedometer.authorizationStatus() {
            case .notDetermined: .notDetermined
            case .restricted, .denied: .denied
            case .authorized: .granted
            @unknown default: .unknown
            }
        case .microphone:
            return switch AVAudioApplication.shared.recordPermission {
            case .undetermined: .notDetermined
            case .denied: .denied
            case .granted: .granted
            @unknown default: .unknown
            }
        case .photos:
            return switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .notDetermined: .notDetermined
            case .restricted, .denied: .denied
            case .authorized, .limited: .granted
            @unknown default: .unknown
            }
        case .mediaLibrary:
            return switch MPMediaLibrary.authorizationStatus() {
            case .notDetermined: .notDetermined
            case .restricted, .denied: .denied
            case .authorized: .granted
            @unknown default: .unknown
            }
        case .focus:
            return switch INFocusStatusCenter.default.authorizationStatus {
            case .notDetermined: .notDetermined
            case .restricted, .denied: .denied
            case .authorized: .granted
            @unknown default: .unknown
            }
        }
    }

    private func stubbedStatus(for permission: SensorPermission) -> SensorPermissionState {
        guard let json = ProcessInfo.processInfo.environment["SENSOR_PERMISSION_STATUSES"],
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data),
              let raw = map[permission.rawValue],
              let state = SensorPermissionState(rawValue: raw) else {
            return .unknown
        }
        return state
    }
}

extension SensorKind {
    /// The permission gating this sensor's readings, or nil when none does
    /// (battery/connection need no authorization; weather and elevation ride
    /// on the location fix; medications have no queryable status — see
    /// SensorPermission). The plan-44 metadata toggles map 1:1 onto real OS
    /// permissions: Motion & Fitness reuses the existing `.motion`
    /// authorization (same dialog PermissionCascade already sequences for the
    /// pedometer), and Device Context has NO permission — it must never
    /// render a Request affordance or count as requestable.
    var permission: SensorPermission? {
        switch self {
        case .location, .weather, .altitude: .location
        case .photos: .photos
        case .audio: .microphone
        case .focus: .focus
        case .healthFlights, .motionFitness: .motion
        case .healthSteps, .healthHeart, .healthHeartRange, .healthHRV, .healthRestingHeart,
             .healthSleep, .healthWorkouts, .healthCaffeine, .healthActivityRings: .health
        case .media: .mediaLibrary
        case .battery, .connection, .healthMedications, .deviceContext: nil
        }
    }
}
