import CoreLocation
import DispatchKit
import Foundation
import MapKit
import os

/// Shares the CLLocation fix between the location, altitude, and weather
/// providers so one report takes one GPS fix. Instantiated PER capture
/// session (never a global singleton) so a stale fix from an earlier report
/// can never be reused, and injected into each dependent provider.
actor LocationFixStore {
    private var fix: CLLocation?
    private var waiters: [CheckedContinuation<CLLocation, Never>] = []

    func store(_ newFix: CLLocation) {
        fix = newFix
        for w in waiters { w.resume(returning: newFix) }
        waiters.removeAll()
    }

    /// Awaits the session's location fix. If a fix has already arrived it
    /// returns immediately; otherwise it suspends until `store` is called.
    /// If no fix EVER arrives (denied permission, provider disabled/hung), the
    /// waiter never resumes — this is exactly the coordinator's abandoned-task
    /// case (see CaptureCoordinator.resolve): the per-provider timeout fires,
    /// cancels this Task, and yields `.unavailable`. Cooperative unwinding of a
    /// `withCheckedContinuation` waiter is not possible here, and that is
    /// acceptable — the report never hangs.
    func awaitFix() async -> CLLocation {
        if let fix { return fix }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// Mutable state for LocationProvider guarded by a single unfair lock so the
/// CLLocationManager delegate callbacks (arbitrary threads) and the async
/// requestFix path never race on the continuation / didRequestLocation flag.
private struct LocationState {
    var continuation: CheckedContinuation<CLLocation, Error>?
    var didRequestLocation = false
}

final class LocationProvider: NSObject, SensorProvider, CLLocationManagerDelegate, @unchecked Sendable {
    let kind = SensorKind.location
    private let manager = CLLocationManager()
    private let store: LocationFixStore
    private let state = OSAllocatedUnfairLock(initialState: LocationState())

    init(store: LocationFixStore) {
        self.store = store
        super.init()
    }

    /// Take the pending continuation (if any) under the lock, single-resume.
    private func takeContinuation() -> CheckedContinuation<CLLocation, Error>? {
        state.withLock { s in
            let c = s.continuation
            s.continuation = nil
            return c
        }
    }

    func capture() async throws -> SensorPayload {
        let fix = try await requestFix()
        await store.store(fix)
        var snapshot = LocationSnapshot(latitude: fix.coordinate.latitude,
                                        longitude: fix.coordinate.longitude)
        snapshot.altitude = fix.altitude
        // The full CLLocation rides the location payload as flat metadata
        // (plan 44, #61) — CoreLocation's negative invalid sentinels degrade
        // to nil via MotionFormatting rather than storing nonsense.
        snapshot.horizontalAccuracy = MotionFormatting.validAccuracy(fix.horizontalAccuracy)
        snapshot.verticalAccuracy = MotionFormatting.validAccuracy(fix.verticalAccuracy)
        snapshot.speed = MotionFormatting.validSpeed(fix.speed)
        snapshot.speedAccuracy = MotionFormatting.validAccuracy(fix.speedAccuracy)
        snapshot.course = MotionFormatting.validCourse(fix.course)
        snapshot.courseAccuracy = MotionFormatting.validAccuracy(fix.courseAccuracy)
        snapshot.floorLevel = fix.floor?.level
        if let source = fix.sourceInformation {
            snapshot.isSimulatedBySoftware = source.isSimulatedBySoftware
            snapshot.isProducedByAccessory = source.isProducedByAccessory
        }
        snapshot.timestamp = fix.timestamp
        // Compass heading (plan 44, #61): a separate CLHeading read (extra
        // magnetometer activation, noted in the plan doc) folded into this
        // provider so it rides the location toggle. Best-effort with an
        // internal timeout — a missing compass (iPad/Mac/simulator) or a slow
        // first sample degrades to nil, never stalling the location capture.
        if let heading = await HeadingReader.read(timeout: .seconds(2)) {
            snapshot.trueHeading = MotionFormatting.validHeading(heading.trueHeading)
            snapshot.magneticHeading = MotionFormatting.validHeading(heading.magneticHeading)
            snapshot.headingAccuracy = MotionFormatting.validAccuracy(heading.accuracy)
        }
        if let placemark = try? await Self.reverseGeocode(fix) {
            snapshot.placemark = placemark
        }
        return .location(snapshot)
    }

    /// Reverse-geocodes via MapKit's MKReverseGeocodingRequest (CLGeocoder's
    /// replacement as of iOS 26). Populates every field MapKit's non-deprecated
    /// surface (MKMapItem.name/location/address/addressRepresentations) can
    /// supply; MKMapItem no longer exposes thoroughfare/subThoroughfare/
    /// subLocality/subAdministrativeArea/postalCode/country without going
    /// through the now-deprecated `placemark` property, so those fields are
    /// left nil rather than reintroducing a deprecation warning. Non-fatal:
    /// callers use `try?`, matching the previous CLGeocoder semantics.
    private static func reverseGeocode(_ location: CLLocation) async throws -> Placemark? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        guard let item = try await request.mapItems.first else { return nil }
        var placemark = Placemark()
        placemark.name = item.name
        placemark.locality = item.addressRepresentations?.cityName
        placemark.country = item.addressRepresentations?.regionName
        return placemark
    }

    private func requestFix() async throws -> CLLocation {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        let status = manager.authorizationStatus
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            return try await withLocationContinuation(requested: true) {
                self.manager.requestLocation()
            }
        case .denied, .restricted:
            throw ProviderError("location permission denied")
        case .notDetermined:
            fallthrough
        @unknown default:
            return try await withLocationContinuation(requested: false) {
                self.manager.requestWhenInUseAuthorization()
            }
        }
    }

    /// Stores the continuation under the lock and wraps the wait in a
    /// cancellation handler so the coordinator's timeout (which cancels this
    /// provider Task) resumes the continuation by throwing — making this
    /// provider cancellation-COOPERATIVE rather than abandoned.
    private func withLocationContinuation(requested: Bool,
                                          _ kickoff: @escaping () -> Void) async throws -> CLLocation {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
                state.withLock { s in
                    s.continuation = continuation
                    s.didRequestLocation = requested
                }
                kickoff()
            }
        } onCancel: {
            takeContinuation()?.resume(throwing: ProviderError("cancelled"))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            // Delegate-set-time transition (or still awaiting the user); ignore.
            return
        case .authorizedWhenInUse, .authorizedAlways:
            let shouldRequest = state.withLock { s -> Bool in
                guard s.continuation != nil, !s.didRequestLocation else { return false }
                s.didRequestLocation = true
                return true
            }
            if shouldRequest { manager.requestLocation() }
        case .denied, .restricted:
            takeContinuation()?.resume(throwing: ProviderError("location permission denied"))
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let fix = locations.last {
            takeContinuation()?.resume(returning: fix)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        takeContinuation()?.resume(throwing: error)
    }
}

struct AltitudeFromLocationProvider: SensorProvider {
    let kind = SensorKind.altitude
    let store: LocationFixStore

    func capture() async throws -> SensorPayload {
        // Awaits the shared session fix. If none ever arrives this hangs
        // cooperatively; the coordinator timeout (see CaptureCoordinator.resolve)
        // abandons the waiter and yields `.unavailable`.
        let fix = await store.awaitFix()
        return .altitude(fix.altitude)
    }
}

/// One-shot compass heading read (plan 44, #61) — CLHeading comes from a
/// separate magnetometer activation, NOT from the CLLocation fix, so it gets
/// its own manager here. Called from LocationProvider.capture (and therefore
/// gated on the location sensor toggle). Single sample, stop immediately,
/// bounded by an internal timeout so a slow/absent compass can never stall
/// the location capture. The continuation carries the extracted values, not
/// the CLHeading itself (CLHeading isn't Sendable).
final class HeadingReader: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    struct Sample: Sendable {
        let trueHeading: Double
        let magneticHeading: Double
        let accuracy: Double
    }

    private let manager = CLLocationManager()
    private let state = OSAllocatedUnfairLock<CheckedContinuation<Sample?, Never>?>(initialState: nil)

    /// Races the first heading sample against `timeout`; nil on no compass
    /// hardware, delegate error, cancellation, or timeout.
    static func read(timeout: Duration) async -> Sample? {
        guard CLLocationManager.headingAvailable() else { return nil }
        let reader = HeadingReader()
        let sample = await withTaskGroup(of: Sample?.self) { group in
            group.addTask { await reader.awaitSample() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await MainActor.run { reader.manager.stopUpdatingHeading() }
        return sample
    }

    private func awaitSample() async -> Sample? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Sample?, Never>) in
                state.withLock { $0 = continuation }
                // Start on the main runloop: CLLocationManager delivers
                // delegate callbacks on the thread that starts updates, and a
                // bare task-pool thread has no runloop to deliver into.
                Task { @MainActor in
                    self.manager.delegate = self
                    self.manager.startUpdatingHeading()
                }
            }
        } onCancel: {
            takeContinuation()?.resume(returning: nil)
        }
    }

    private func takeContinuation() -> CheckedContinuation<Sample?, Never>? {
        state.withLock { c in
            let result = c
            c = nil
            return result
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        manager.stopUpdatingHeading()
        let sample = Sample(trueHeading: newHeading.trueHeading,
                            magneticHeading: newHeading.magneticHeading,
                            accuracy: newHeading.headingAccuracy)
        takeContinuation()?.resume(returning: sample)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        manager.stopUpdatingHeading()
        takeContinuation()?.resume(returning: nil)
    }
}
