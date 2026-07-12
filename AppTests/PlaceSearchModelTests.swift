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
        radius: Double = MonitorDelay.floorRadiusMeters
    ) -> PlaceSearchModel {
        PlaceSearchModel(
            completer: StubPlaceCompleter(catalog: catalog),
            resolver: StubPlaceResolver(defaultRadius: radius, shouldFail: shouldFail))
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
}
