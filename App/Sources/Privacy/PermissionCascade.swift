import AVFAudio
import CoreLocation
import CoreMotion
import DispatchKit
import Foundation
import Intents
import os
import Photos
import SwiftUI

private let cascadeLog = Logger(subsystem: "io.robbie.Dispatch", category: "permission-cascade")

/// Runs every sensor permission dialog Dispatch will ever need, ONE AT A
/// TIME, awaited in sequence. Sheets/dialogs presented by different system
/// frameworks (Core Location, HealthKit, AVAudioApplication, Photos,
/// SiriKit/Focus, UserNotifications) do not coordinate with each other — if
/// two are requested concurrently they stack or silently drop, and the
/// *first-capture* dialog storm this cascade exists to prevent is exactly
/// that failure mode. Every step is independently failure-tolerant: a
/// denial or a thrown error just moves on to the next permission rather than
/// aborting the whole cascade.
///
/// Completely bypassed under `--ui-testing`/`--mock-sensors` (same gate as
/// NotificationScheduler/AppLockStore/SpotlightIndexer) so UI tests never
/// hit a system permission dialog, which would hang the test runner.
@MainActor
@Observable
final class PermissionCascade {
    private(set) var isRequesting = false

    /// Defaults flag marking that the Motion + medications cascade steps
    /// (added after build 7) have been requested at least once — set by
    /// `requestAll()` (fresh installs, onboarding) and by
    /// `runUpgradeTopUpIfNeeded()` (existing installs that completed
    /// onboarding before these steps existed).
    static let motionMedicationsRequestedKey = "permissions.motionMedicationsRequested"

    let isTestEnvironment: Bool
    private let locationRequester: CascadeLocationRequester
    private let healthReader: HealthKitReader
    private let notificationScheduler: NotificationScheduler
    private let notificationPrefs: NotificationPrefs
    private let awakeStore: AwakeStore
    private let defaults: UserDefaults

    init(
        healthReader: HealthKitReader,
        notificationScheduler: NotificationScheduler,
        notificationPrefs: NotificationPrefs,
        awakeStore: AwakeStore,
        defaults: UserDefaults = .standard,
        isTestEnvironment: Bool? = nil
    ) {
        self.healthReader = healthReader
        self.notificationScheduler = notificationScheduler
        self.notificationPrefs = notificationPrefs
        self.awakeStore = awakeStore
        self.defaults = defaults
        self.locationRequester = CascadeLocationRequester()
        self.isTestEnvironment = isTestEnvironment ?? {
            let arguments = ProcessInfo.processInfo.arguments
            return arguments.contains("--mock-sensors") || arguments.contains("--ui-testing")
        }()
    }

    /// Requests every sensor permission Dispatch uses, strictly
    /// sequentially: location -> HealthKit -> microphone -> photos -> Focus
    /// -> notifications. Each step is awaited to completion (or its bound
    /// timeout) before the next one is kicked off, so at most one system
    /// dialog is ever on screen. No-op, instantly, in test mode.
    func requestAll() async {
        guard !isTestEnvironment else { return }
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }

        await requestLocation()
        await requestHealth()
        await requestMedications()
        await requestMotion()
        await requestMicrophone()
        await requestPhotos()
        await requestFocus()
        requestNotifications()
        // Full cascade covers the post-build-7 Motion/medications steps, so
        // the upgrade top-up below must never re-run them.
        defaults.set(true, forKey: Self.motionMedicationsRequestedKey)
    }

    /// One-time top-up for installs that completed onboarding BEFORE the
    /// Motion and medications cascade steps existed: their `requestAll()`
    /// already ran, so those two dialogs would otherwise ambush the next
    /// capture (Motion) or silently never be requested (medications). Runs
    /// JUST the new steps, sequentially awaited like the full cascade, then
    /// sets the same defaults flag `requestAll()` sets. Callers gate on the
    /// onboarding-complete flag; fresh installs get the flag from
    /// `requestAll()` and skip this entirely. No-op in test mode.
    func runUpgradeTopUpIfNeeded() async {
        guard !isTestEnvironment else { return }
        guard !defaults.bool(forKey: Self.motionMedicationsRequestedKey) else { return }
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }

        await requestMotion()
        await requestMedications()
        defaults.set(true, forKey: Self.motionMedicationsRequestedKey)
    }

    private func requestLocation() async {
        await locationRequester.requestWhenInUseAuthorization()
    }

    private func requestHealth() async {
        do {
            try await healthReader.authorize()
        } catch {
            cascadeLog.error("health permission request failed: \(error, privacy: .public)")
        }
    }

    /// Medications join the standard flow (user decision, plan 14 T5) but as
    /// their OWN sequenced step: the medication types must NEVER enter the
    /// bulk requestAuthorization read set — that exact mistake crashed a
    /// device with an uncatchable NSInvalidArgumentException (Swift cannot
    /// catch NSExceptions). iOS 26 medications authorize per-object, like
    /// vision prescriptions (`requestPerObjectReadAuthorization`). Denial or
    /// error just moves the cascade along; capture degrades to unavailable.
    private func requestMedications() async {
        do {
            try await healthReader.authorizeMedications()
        } catch {
            cascadeLog.error("medication per-object authorization failed: \(error, privacy: .public)")
        }
    }

    /// Core Motion (CMPedometer, flights descended) has no standalone
    /// requestAuthorization API — the permission dialog fires on the first
    /// query. Issue a tiny bounded query here so the Motion dialog takes its
    /// place IN SEQUENCE instead of ambushing the first report capture.
    /// The query is issued directly (not via `PedometerReader`, which
    /// deliberately refuses to query while `.notDetermined` so capture paths
    /// can never trigger this dialog) — this is the ONE place allowed to
    /// query in the undetermined state.
    private func requestMotion() async {
        guard CMPedometer.isFloorCountingAvailable(),
              CMPedometer.authorizationStatus() == .notDetermined else { return }
        let now = Date()
        let pedometer = CMPedometer()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pedometer.queryPedometerData(from: now.addingTimeInterval(-60), to: now) { _, _ in
                continuation.resume()
            }
        }
    }

    private func requestMicrophone() async {
        _ = await AVAudioApplication.requestRecordPermission()
    }

    private func requestPhotos() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    private func requestFocus() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            INFocusStatusCenter.default.requestAuthorization { _ in
                continuation.resume()
            }
        }
    }

    /// Notification permission uses the existing callback-based scheduler
    /// path rather than a fresh request, so category registration/replan
    /// stays centralized in one place. Fire-and-forget is acceptable here
    /// because it's always the LAST step in the cascade.
    private func requestNotifications() {
        notificationScheduler.requestPermissionIfNeeded(prefs: notificationPrefs, awakeStore: awakeStore)
    }
}

/// Minimal, cascade-owned CLLocationManager wrapper. Deliberately NOT shared
/// with `LocationProvider` (per-capture-session GPS fix owner) — this only
/// ever needs to trigger the system permission prompt once and observe the
/// resulting authorization status; it never requests an actual fix.
@MainActor
private final class CascadeLocationRequester: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    /// Awaits the authorization status change, bounded by a generous 45s
    /// hang-guard in case the system never calls back. The bound must be
    /// long: the permission alert can legitimately stay on screen while the
    /// user decides, and resuming early would stack the next cascade sheet
    /// underneath it. The `notDetermined` guard covers the no-dialog case and
    /// the delegate callback covers the normal case, so this timer never
    /// fires in practice.
    func requestWhenInUseAuthorization() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            manager.requestWhenInUseAuthorization()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                self?.resumeIfNeeded()
            }
        }
    }

    private func resumeIfNeeded() {
        continuation?.resume()
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.resumeIfNeeded()
        }
    }
}
