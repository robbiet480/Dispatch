import CoreLocation
import DispatchKit
import Foundation

/// Shares the CLLocation fix between the location, altitude, and weather
/// providers so one report takes one GPS fix.
actor LocationFixStore {
    static let shared = LocationFixStore()
    private(set) var lastFix: CLLocation?
    func store(_ fix: CLLocation) { lastFix = fix }
}

final class LocationProvider: NSObject, SensorProvider, CLLocationManagerDelegate, @unchecked Sendable {
    let kind = SensorKind.location
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var didRequestLocation = false

    func capture() async throws -> SensorPayload {
        let fix = try await requestFix()
        await LocationFixStore.shared.store(fix)
        var snapshot = LocationSnapshot(latitude: fix.coordinate.latitude,
                                        longitude: fix.coordinate.longitude)
        snapshot.altitude = fix.altitude
        snapshot.horizontalAccuracy = fix.horizontalAccuracy
        snapshot.verticalAccuracy = fix.verticalAccuracy
        snapshot.speed = fix.speed
        snapshot.course = fix.course
        snapshot.timestamp = fix.timestamp
        if let clPlacemark = try? await CLGeocoder().reverseGeocodeLocation(fix).first {
            var placemark = Placemark()
            placemark.name = clPlacemark.name
            placemark.thoroughfare = clPlacemark.thoroughfare
            placemark.subThoroughfare = clPlacemark.subThoroughfare
            placemark.locality = clPlacemark.locality
            placemark.subLocality = clPlacemark.subLocality
            placemark.administrativeArea = clPlacemark.administrativeArea
            placemark.subAdministrativeArea = clPlacemark.subAdministrativeArea
            placemark.postalCode = clPlacemark.postalCode
            placemark.country = clPlacemark.country
            snapshot.placemark = placemark
        }
        return .location(snapshot)
    }

    private func requestFix() async throws -> CLLocation {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        let status = manager.authorizationStatus
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.didRequestLocation = true
                manager.requestLocation()
            }
        case .denied, .restricted:
            throw ProviderError("location permission denied")
        case .notDetermined:
            fallthrough
        @unknown default:
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.didRequestLocation = false
                manager.requestWhenInUseAuthorization()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard continuation != nil else { return }
        switch status {
        case .notDetermined:
            // Delegate-set-time transition (or still awaiting the user); ignore.
            return
        case .authorizedWhenInUse, .authorizedAlways:
            guard !didRequestLocation else { return }
            didRequestLocation = true
            manager.requestLocation()
        case .denied, .restricted:
            let pending = continuation
            continuation = nil
            pending?.resume(throwing: ProviderError("location permission denied"))
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let fix = locations.last {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: fix)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: error)
    }
}

struct AltitudeFromLocationProvider: SensorProvider {
    let kind = SensorKind.altitude

    func capture() async throws -> SensorPayload {
        // Location provider runs concurrently; wait briefly for its fix.
        for _ in 0..<20 {
            if let fix = await LocationFixStore.shared.lastFix {
                return .altitude(fix.altitude)
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw ProviderError("no location fix for altitude")
    }
}
