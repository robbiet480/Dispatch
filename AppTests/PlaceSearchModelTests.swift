import DispatchKit
import XCTest

/// Plan 50 (#83): the shared place-search wrapper is TDD'd with in-process
/// stubs — no MapKit network. `PlaceSearch.swift` is compiled directly into
/// this hostless bundle (see project.yml), so the stub completer/resolver are
/// available without `@testable import`.
@MainActor
final class PlaceSearchModelTests: XCTestCase {
    private func makeModel(
        catalog: [PlaceSuggestion] = StubPlaceCompleter.defaultCatalog,
        shouldFail: Bool = false,
        radius: Double = MonitorDelay.floorRadiusMeters,
        currentLocation: StubCurrentLocationProvider = StubCurrentLocationProvider(
            outcome: .place(name: "Current location", latitude: 1.0, longitude: 2.0))
    ) -> PlaceSearchModel {
        PlaceSearchModel(
            completer: StubPlaceCompleter(catalog: catalog),
            resolver: StubPlaceResolver(defaultRadius: radius, shouldFail: shouldFail),
            currentLocation: currentLocation,
            defaultRadius: radius)
    }

    func testTypingPopulatesSuggestions() {
        let model = makeModel()
        model.updateQuery("gym")
        XCTAssertEqual(model.suggestions.map(\.title), ["The Gym"])
    }

    func testMatchesTitleAndSubtitleCaseInsensitively() {
        let model = makeModel()
        model.updateQuery("cupertino") // only HQ's subtitle contains it
        XCTAssertEqual(model.suggestions.map(\.title), ["HQ"])
    }

    func testEmptyOrWhitespaceQueryClearsSuggestions() {
        let model = makeModel()
        model.updateQuery("HQ")
        XCTAssertFalse(model.suggestions.isEmpty)
        model.updateQuery("   ")
        XCTAssertTrue(model.suggestions.isEmpty)
    }

    func testSelectResolvesToCoordinateAndClearsSuggestions() async {
        let model = makeModel()
        model.updateQuery("HQ")
        let picked = try? XCTUnwrap(model.suggestions.first)
        let resolved = await model.select(picked!)
        XCTAssertEqual(resolved?.name, "HQ")
        XCTAssertEqual(resolved?.latitude ?? 0, 37.3349, accuracy: 0.0001)
        XCTAssertEqual(resolved?.longitude ?? 0, -122.009, accuracy: 0.0001)
        XCTAssertEqual(model.resolvedPlace, resolved)
        // Picking collapses the results list.
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testSelectSuggestsTheDefaultRadius() async {
        let model = makeModel(radius: MonitorDelay.floorRadiusMeters)
        model.updateQuery("Home")
        let resolved = await model.select(model.suggestions[0])
        XCTAssertEqual(resolved?.suggestedRadius, MonitorDelay.floorRadiusMeters)
    }

    func testResolveFailureSetsErrorMessageAndReturnsNil() async {
        let model = makeModel(shouldFail: true)
        model.updateQuery("HQ")
        let resolved = await model.select(model.suggestions[0])
        XCTAssertNil(resolved)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.resolvedPlace)
    }

    func testClearResetsState() async {
        let model = makeModel()
        model.updateQuery("HQ")
        model.clear()
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - Use current location

    func testUseCurrentLocationFillsResolvedPlaceWithDefaultRadius() async {
        let model = makeModel(
            radius: MonitorDelay.floorRadiusMeters,
            currentLocation: StubCurrentLocationProvider(
                outcome: .place(name: "Cupertino", latitude: 37.33, longitude: -122.03)))
        model.updateQuery("HQ") // prime some suggestions to prove they clear
        let resolved = await model.useCurrentLocation()
        XCTAssertEqual(resolved?.name, "Cupertino")
        XCTAssertEqual(resolved?.latitude ?? 0, 37.33, accuracy: 0.0001)
        XCTAssertEqual(resolved?.longitude ?? 0, -122.03, accuracy: 0.0001)
        XCTAssertEqual(resolved?.suggestedRadius, MonitorDelay.floorRadiusMeters)
        XCTAssertEqual(model.resolvedPlace, resolved)
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testUseCurrentLocationDeniedSetsActionableError() async {
        let model = makeModel(
            currentLocation: StubCurrentLocationProvider(outcome: .failure(.denied)))
        let resolved = await model.useCurrentLocation()
        XCTAssertNil(resolved)
        XCTAssertNil(model.resolvedPlace)
        XCTAssertEqual(model.errorMessage,
            "Location access is off — allow it in Settings to use your current location, or search by name.")
    }

    func testUseCurrentLocationUnavailableSetsRetryError() async {
        let model = makeModel(
            currentLocation: StubCurrentLocationProvider(outcome: .failure(.unavailable)))
        let resolved = await model.useCurrentLocation()
        XCTAssertNil(resolved)
        XCTAssertNotNil(model.errorMessage)
    }
}
