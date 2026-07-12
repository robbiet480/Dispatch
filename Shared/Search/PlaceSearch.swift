import CoreLocation
import DispatchKit
import Foundation
import MapKit
import Observation
import os

private let placeSearchLog = Logger(subsystem: "io.robbie.Dispatch", category: "place-search")

/// As-you-type place search + geocoding for the place-trigger editors (plan 50,
/// issue #83). Lets the user type a **name or address**, pick an autocomplete
/// suggestion, and geocode it to a coordinate + a default radius — instead of
/// hand-typing latitude/longitude. Usable on iOS AND macOS.
///
/// **Why this lives in `Shared/Search` and not DispatchKit:** DispatchKit is
/// Foundation/SwiftData-only (no MapKit), the same reason the CoreLocation /
/// WeatherKit / HealthKit providers live in `Shared/Providers`. This file is
/// compiled into BOTH `DispatchApp` and `DispatchMac` via dual target
/// membership (see `project.yml`) — the `Shared/Providers` pattern, one
/// directory over.
///
/// **Mockability:** the completer and the resolver are behind the
/// `PlaceCompleting` / `PlaceResolving` protocols so tests inject in-process
/// stubs and never touch the network. `PlaceSearchModel.makeForCurrentProcess`
/// swaps in a canned stub pair under the `--stub-place-search` launch argument
/// (deterministic UI tests).

// MARK: - Value types

/// One as-you-type autocomplete suggestion. Carries the underlying MapKit
/// completion (nil in stubs) so the resolver can geocode the exact pick; the
/// completion is excluded from identity/equality (title+subtitle is the key).
struct PlaceSuggestion: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    /// The MapKit completion to resolve, or nil for a stub/text suggestion (the
    /// stub resolver keys off `title`; the MapKit resolver falls back to a
    /// natural-language query).
    let completion: MKLocalSearchCompletion?

    init(title: String, subtitle: String, completion: MKLocalSearchCompletion? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.completion = completion
        // U+0001 separator keeps distinct title/subtitle pairs distinct even if
        // one contains the other's text.
        self.id = title + "\u{1}" + subtitle
    }

    init(completion: MKLocalSearchCompletion) {
        self.init(title: completion.title, subtitle: completion.subtitle, completion: completion)
    }

    static func == (lhs: PlaceSuggestion, rhs: PlaceSuggestion) -> Bool { lhs.id == rhs.id }
}

/// A resolved (geocoded) place: a coordinate, a display name, and a suggested
/// radius (defaults to `MonitorDelay.floorRadiusMeters`, kept editable).
struct ResolvedPlace: Equatable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
    var suggestedRadius: Double
}

enum PlaceSearchError: Error { case notFound }

// MARK: - Protocols (mock seams)

/// As-you-type autocomplete source. Abstracted so tests inject an in-process
/// stub instead of `MKLocalSearchCompleter` (which queries Apple's servers).
@MainActor
protocol PlaceCompleting: AnyObject {
    var onResults: (([PlaceSuggestion]) -> Void)? { get set }
    var onFailure: ((any Error) -> Void)? { get set }
    func update(query: String)
    func cancel()
}

/// Resolves a chosen suggestion to a coordinate + display name. `@MainActor` so
/// the (non-Sendable) `MKLocalSearchCompletion` never crosses an actor
/// boundary — MapKit resolution runs on the main actor and suspends on the
/// network await.
@MainActor
protocol PlaceResolving {
    func resolve(_ suggestion: PlaceSuggestion) async throws -> ResolvedPlace
}

/// Why a "Use my current location" fetch failed — mapped to an actionable
/// inline message by `PlaceSearchModel`.
enum CurrentLocationError: Error, Equatable {
    /// Location access is off (denied or restricted) — point the user at Settings.
    case denied
    /// No fix (timeout / hardware / transient) — offer retry or search instead.
    case unavailable
}

/// One-shot current-location source (plan 50 follow-up, #83). Behind a protocol
/// so tests inject a stub — no real CoreLocation under test. `@MainActor` for the
/// same reason as `PlaceResolving`: nothing non-Sendable crosses an actor hop.
@MainActor
protocol CurrentLocationProviding {
    /// Requests authorization if needed, takes one location fix, and resolves it
    /// to a place (name reverse-geocoded when possible, else "Current location").
    /// Throws `CurrentLocationError` on denied/restricted/unavailable.
    func currentPlace(defaultRadius: Double) async throws -> ResolvedPlace
}

// MARK: - Model

@MainActor
@Observable
final class PlaceSearchModel {
    /// Current autocomplete suggestions for the typed query.
    private(set) var suggestions: [PlaceSuggestion] = []
    /// True while a picked suggestion is geocoding.
    private(set) var isResolving = false
    /// User-facing message when a pick fails to geocode (nil otherwise).
    private(set) var errorMessage: String?
    /// The most recently resolved place (set by `select`).
    private(set) var resolvedPlace: ResolvedPlace?

    @ObservationIgnored private let completer: any PlaceCompleting
    @ObservationIgnored private let resolver: any PlaceResolving
    @ObservationIgnored private let currentLocation: any CurrentLocationProviding
    @ObservationIgnored private let defaultRadius: Double

    init(completer: any PlaceCompleting,
         resolver: any PlaceResolving,
         currentLocation: any CurrentLocationProviding,
         defaultRadius: Double = MonitorDelay.floorRadiusMeters) {
        self.completer = completer
        self.resolver = resolver
        self.currentLocation = currentLocation
        self.defaultRadius = defaultRadius
        completer.onResults = { [weak self] results in
            self?.suggestions = results
        }
        // Completer failures are routine (no match for the current fragment) —
        // clear the list quietly rather than flashing an error; only a failed
        // PICK (resolve) surfaces `errorMessage`.
        completer.onFailure = { [weak self] error in
            placeSearchLog.debug("completer failure: \(error, privacy: .public)")
            self?.suggestions = []
        }
    }

    /// Feeds a new query to the completer. Empty/whitespace clears the results.
    func updateQuery(_ text: String) {
        errorMessage = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            completer.cancel()
            return
        }
        completer.update(query: trimmed)
    }

    /// Geocodes a picked suggestion. Returns the resolved place (and stores it),
    /// or nil on failure (with `errorMessage` set). Clears the suggestion list.
    @discardableResult
    func select(_ suggestion: PlaceSuggestion) async -> ResolvedPlace? {
        isResolving = true
        errorMessage = nil
        defer { isResolving = false }
        do {
            let place = try await resolver.resolve(suggestion)
            resolvedPlace = place
            suggestions = []
            return place
        } catch {
            placeSearchLog.error("resolve failed: \(error, privacy: .public)")
            errorMessage = "Couldn't find that place. Try a more specific name or address."
            return nil
        }
    }

    /// "Use my current location": takes a one-shot fix and resolves it to a
    /// place. Returns the resolved place (and stores it), or nil on failure with
    /// an actionable `errorMessage`. Clears the suggestion list on success.
    @discardableResult
    func useCurrentLocation() async -> ResolvedPlace? {
        isResolving = true
        errorMessage = nil
        defer { isResolving = false }
        do {
            let place = try await currentLocation.currentPlace(defaultRadius: defaultRadius)
            resolvedPlace = place
            suggestions = []
            return place
        } catch let error as CurrentLocationError {
            errorMessage = Self.message(for: error)
            return nil
        } catch {
            placeSearchLog.error("current location failed: \(error, privacy: .public)")
            errorMessage = "Couldn't get your current location. Try again, or search by name."
            return nil
        }
    }

    private static func message(for error: CurrentLocationError) -> String {
        switch error {
        case .denied:
            "Location access is off — allow it in Settings to use your current location, or search by name."
        case .unavailable:
            "Couldn't get your current location. Try again, or search by name."
        }
    }

    /// Resets the search (clears results, error, and any pending completion).
    func clear() {
        suggestions = []
        errorMessage = nil
        completer.cancel()
    }

    /// The editor's search model: a canned stub under `--stub-place-search`
    /// (deterministic UI tests, no network), the real MapKit/CoreLocation
    /// implementations otherwise.
    static func makeForCurrentProcess(
        defaultRadius: Double = MonitorDelay.floorRadiusMeters
    ) -> PlaceSearchModel {
        if ProcessInfo.processInfo.arguments.contains("--stub-place-search") {
            return PlaceSearchModel(
                completer: StubPlaceCompleter(),
                resolver: StubPlaceResolver(defaultRadius: defaultRadius),
                currentLocation: StubCurrentLocationProvider(
                    outcome: .place(name: "Current location", latitude: 37.3349, longitude: -122.009)),
                defaultRadius: defaultRadius)
        }
        return PlaceSearchModel(
            completer: MapKitPlaceCompleter(),
            resolver: MapKitPlaceResolver(defaultRadius: defaultRadius),
            currentLocation: CoreLocationCurrentLocationProvider(),
            defaultRadius: defaultRadius)
    }
}

// MARK: - MapKit adapters (production)

/// `MKLocalSearchCompleter`-backed autocomplete. Biases toward *resolvable*
/// places (`.address` / `.pointOfInterest`) rather than category queries.
@MainActor
final class MapKitPlaceCompleter: NSObject, PlaceCompleting {
    var onResults: (([PlaceSuggestion]) -> Void)?
    var onFailure: ((any Error) -> Void)?
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) { completer.queryFragment = query }
    func cancel() { completer.cancel() }
}

// MKLocalSearchCompleter delivers its delegate callbacks on the MAIN thread
// (documented), so the `nonisolated` methods safely `assumeIsolated` back onto
// the main actor — the Swift 6 bridge for a main-thread delegate whose protocol
// isn't itself actor-annotated.
extension MapKitPlaceCompleter: MKLocalSearchCompleterDelegate {
    // Read the stored `completer` (identical to the callback's argument, which
    // we set as the delegate) rather than the non-Sendable parameter, so nothing
    // is "sent" into the main-actor region.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            onResults?(self.completer.results.map(PlaceSuggestion.init(completion:)))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            onFailure?(error)
        }
    }
}

/// `MKLocalSearch`-backed geocoder. Resolves the picked completion to an
/// `MKMapItem` and reads its coordinate off `location` — the iOS/macOS-26
/// non-deprecated surface (`MKMapItem.placemark` is deprecated in 26; the
/// existing `LocationProvider` reverse-geocode already migrated off it).
@MainActor
struct MapKitPlaceResolver: PlaceResolving {
    let defaultRadius: Double

    func resolve(_ suggestion: PlaceSuggestion) async throws -> ResolvedPlace {
        let search: MKLocalSearch
        if let completion = suggestion.completion {
            search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        } else {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = [suggestion.title, suggestion.subtitle]
                .filter { !$0.isEmpty }.joined(separator: " ")
            search = MKLocalSearch(request: request)
        }
        // Extract the coordinate + name inside the completion handler and resume
        // with the (Sendable) `ResolvedPlace` — the non-Sendable
        // MKLocalSearch.Response never crosses the continuation. `MKMapItem.location`
        // (iOS/macOS 26, non-deprecated) is non-optional for a geocoded result.
        let fallbackName = suggestion.title
        let radius = defaultRadius
        return try await withCheckedThrowingContinuation { continuation in
            search.start { response, error in
                guard let item = response?.mapItems.first else {
                    continuation.resume(throwing: error ?? PlaceSearchError.notFound)
                    return
                }
                let coordinate = item.location.coordinate
                continuation.resume(returning: ResolvedPlace(
                    name: item.name ?? fallbackName,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    suggestedRadius: radius))
            }
        }
    }
}

/// `CLLocationManager`-backed one-shot current-location fetch (+ best-effort
/// reverse-geocoded name). Requests **when-in-use** authorization if needed —
/// enough for a single fix; the app's Always upgrade (for background monitoring)
/// is a separate flow. `CLLocationManagerDelegate` callbacks arrive on the main
/// thread, so the `nonisolated` delegate methods `assumeIsolated` back on-actor
/// (the same bridge as `MapKitPlaceCompleter`).
@MainActor
final class CoreLocationCurrentLocationProvider: NSObject, CurrentLocationProviding {
    /// A Sendable coordinate carried across the continuation (CLLocation isn't
    /// Sendable; two Doubles are).
    private struct Fix: Sendable {
        let latitude: Double
        let longitude: Double
    }

    private let manager = CLLocationManager()
    private var fixContinuation: CheckedContinuation<Fix, any Error>?
    /// True while waiting for the authorization decision before requesting a fix.
    private var awaitingAuthorization = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentPlace(defaultRadius: Double) async throws -> ResolvedPlace {
        let fix = try await requestFix()
        let location = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        let name = await Self.reverseGeocodedName(location)
        return ResolvedPlace(name: name ?? "Current location",
                             latitude: fix.latitude,
                             longitude: fix.longitude,
                             suggestedRadius: defaultRadius)
    }

    private func requestFix() async throws -> Fix {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return try await withFixContinuation(requestLocationNow: true)
        case .denied, .restricted:
            throw CurrentLocationError.denied
        case .notDetermined:
            return try await withFixContinuation(requestLocationNow: false)
        @unknown default:
            throw CurrentLocationError.unavailable
        }
    }

    private func withFixContinuation(requestLocationNow: Bool) async throws -> Fix {
        try await withCheckedThrowingContinuation { continuation in
            fixContinuation = continuation
            if requestLocationNow {
                awaitingAuthorization = false
                manager.requestLocation()
            } else {
                awaitingAuthorization = true
                manager.requestWhenInUseAuthorization()
            }
        }
    }

    private func resume(returning fix: Fix) {
        fixContinuation?.resume(returning: fix)
        fixContinuation = nil
    }

    private func resume(throwing error: any Error) {
        fixContinuation?.resume(throwing: error)
        fixContinuation = nil
    }

    /// Best-effort place name via MapKit reverse geocoding (the non-deprecated
    /// `MKReverseGeocodingRequest`, matching `LocationProvider`). nil ⇒ caller
    /// falls back to "Current location".
    private static func reverseGeocodedName(_ location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let item = try? await request.mapItems.first
        return item?.name
    }
}

extension CoreLocationCurrentLocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard awaitingAuthorization else { return }
            switch self.manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                awaitingAuthorization = false
                self.manager.requestLocation()
            case .denied, .restricted:
                awaitingAuthorization = false
                resume(throwing: CurrentLocationError.denied)
            case .notDetermined:
                return // still waiting on the user
            @unknown default:
                awaitingAuthorization = false
                resume(throwing: CurrentLocationError.unavailable)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Extract Sendable Doubles in the nonisolated context so nothing
        // non-Sendable crosses into the main-actor region.
        guard let coordinate = locations.last?.coordinate else { return }
        let fix = Fix(latitude: coordinate.latitude, longitude: coordinate.longitude)
        MainActor.assumeIsolated {
            resume(returning: fix)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            resume(throwing: CurrentLocationError.unavailable)
        }
    }
}

// MARK: - Stubs (tests + `--stub-place-search` UI runs)

/// In-process autocomplete stub — filters a canned catalog by case-insensitive
/// substring so tests and UI runs never hit the network.
@MainActor
final class StubPlaceCompleter: PlaceCompleting {
    var onResults: (([PlaceSuggestion]) -> Void)?
    var onFailure: ((any Error) -> Void)?
    var catalog: [PlaceSuggestion]

    init(catalog: [PlaceSuggestion] = StubPlaceCompleter.defaultCatalog) {
        self.catalog = catalog
    }

    func update(query: String) {
        let needle = query.lowercased()
        onResults?(catalog.filter {
            $0.title.lowercased().contains(needle) || $0.subtitle.lowercased().contains(needle)
        })
    }

    func cancel() { onResults?([]) }

    static let defaultCatalog: [PlaceSuggestion] = [
        PlaceSuggestion(title: "HQ", subtitle: "1 Infinite Loop, Cupertino, CA"),
        PlaceSuggestion(title: "Home", subtitle: "123 Main St, Springfield"),
        PlaceSuggestion(title: "The Gym", subtitle: "500 Fitness Way"),
    ]
}

/// Resolver stub — returns a fixed coordinate keyed by suggestion title so
/// tests/UI runs assert a deterministic place.
@MainActor
struct StubPlaceResolver: PlaceResolving {
    let defaultRadius: Double
    var coordinatesByTitle: [String: (latitude: Double, longitude: Double)]
    var shouldFail: Bool

    init(defaultRadius: Double,
         coordinatesByTitle: [String: (latitude: Double, longitude: Double)] = [
            "HQ": (37.3349, -122.009),
            "Home": (39.7817, -89.6501),
            "The Gym": (40.0, -74.0),
         ],
         shouldFail: Bool = false) {
        self.defaultRadius = defaultRadius
        self.coordinatesByTitle = coordinatesByTitle
        self.shouldFail = shouldFail
    }

    func resolve(_ suggestion: PlaceSuggestion) async throws -> ResolvedPlace {
        if shouldFail { throw PlaceSearchError.notFound }
        let coordinate = coordinatesByTitle[suggestion.title] ?? (latitude: 0, longitude: 0)
        return ResolvedPlace(name: suggestion.title,
                             latitude: coordinate.latitude,
                             longitude: coordinate.longitude,
                             suggestedRadius: defaultRadius)
    }
}

/// Current-location stub — returns a fixed place or a chosen error so tests and
/// UI runs never touch CoreLocation. Builds the `ResolvedPlace` with the caller's
/// `defaultRadius` so the radius fill is asserted.
@MainActor
final class StubCurrentLocationProvider: CurrentLocationProviding {
    enum Outcome {
        case place(name: String, latitude: Double, longitude: Double)
        case failure(CurrentLocationError)
    }

    var outcome: Outcome

    init(outcome: Outcome) { self.outcome = outcome }

    func currentPlace(defaultRadius: Double) async throws -> ResolvedPlace {
        switch outcome {
        case .place(let name, let latitude, let longitude):
            return ResolvedPlace(name: name, latitude: latitude,
                                 longitude: longitude, suggestedRadius: defaultRadius)
        case .failure(let error):
            throw error
        }
    }
}
