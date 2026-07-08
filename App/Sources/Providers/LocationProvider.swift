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
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let fix = locations.last {
            continuation?.resume(returning: fix)
            continuation = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
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
