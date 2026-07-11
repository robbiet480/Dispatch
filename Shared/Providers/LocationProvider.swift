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
        snapshot.horizontalAccuracy = fix.horizontalAccuracy
        snapshot.verticalAccuracy = fix.verticalAccuracy
        snapshot.speed = fix.speed
        snapshot.course = fix.course
        snapshot.timestamp = fix.timestamp
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

/// Speed off the same shared location fix (plan 43, #61) — mirrors
/// AltitudeFromLocationProvider exactly, degrading CoreLocation's invalid-
/// reading sentinel (negative `speed`) to `.unavailable` via MotionFormatting
/// rather than capturing a nonsensical value.
struct SpeedFromLocationProvider: SensorProvider {
    let kind = SensorKind.speed
    let store: LocationFixStore

    func capture() async throws -> SensorPayload {
        let fix = await store.awaitFix()
        guard let speed = MotionFormatting.validSpeed(fix.speed) else {
            throw ProviderError("no valid speed reading")
        }
        return .speed(speed)
    }
}

/// Course (direction of travel) off the same shared location fix (plan 43,
/// #61) — mirrors AltitudeFromLocationProvider/SpeedFromLocationProvider.
struct CourseFromLocationProvider: SensorProvider {
    let kind = SensorKind.course
    let store: LocationFixStore

    func capture() async throws -> SensorPayload {
        let fix = await store.awaitFix()
        guard let course = MotionFormatting.validCourse(fix.course) else {
            throw ProviderError("no valid course reading")
        }
        return .course(course)
    }
}

/// Compass heading (plan 43, #61) — a distinct magnetometer read via its own
/// CLLocationManager, NOT derived from the shared location fix (different
/// data source, independently device-gated: `headingAvailable()` is false on
/// iPad/Mac/Watch). Takes exactly one delegate sample then stops, same
/// single-shot shape as LocationProvider.requestFix.
final class HeadingProvider: NSObject, SensorProvider, CLLocationManagerDelegate, @unchecked Sendable {
    let kind = SensorKind.heading
    private let manager = CLLocationManager()
    // The continuation carries the extracted Double, not the CLHeading
    // itself — CLHeading isn't Sendable, and the value is all this provider
    // needs from the delegate callback.
    private let state = OSAllocatedUnfairLock<CheckedContinuation<Double, Error>?>(initialState: nil)

    func capture() async throws -> SensorPayload {
        guard CLLocationManager.headingAvailable() else {
            throw ProviderError("heading not available on this device")
        }
        let degrees = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
                state.withLock { $0 = continuation }
                manager.delegate = self
                manager.startUpdatingHeading()
            }
        } onCancel: {
            takeContinuation()?.resume(throwing: ProviderError("cancelled"))
        }
        return .heading(degrees)
    }

    private func takeContinuation() -> CheckedContinuation<Double, Error>? {
        state.withLock { c in
            let result = c
            c = nil
            return result
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        manager.stopUpdatingHeading()
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        takeContinuation()?.resume(returning: degrees)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        manager.stopUpdatingHeading()
        takeContinuation()?.resume(throwing: error)
    }
}
