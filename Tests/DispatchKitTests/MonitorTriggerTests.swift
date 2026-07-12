import Foundation
import Testing
@testable import DispatchKit

// MARK: - Radius floor

@Test func placeRegionClampsRadiusToFloor() {
    let tight = MonitorPlaceRegion(latitude: 37.33, longitude: -122.03, radius: 10)
    #expect(tight.radius == MonitorDelay.floorRadiusMeters)

    let honest = MonitorPlaceRegion(latitude: 37.33, longitude: -122.03, radius: 250)
    #expect(honest.radius == 250)
}

@Test func placeRegionDecodeAlsoAppliesFloor() throws {
    // A hand-edited export with a sub-floor radius must not sneak past.
    let json = #"{"latitude":1.0,"longitude":2.0,"radius":5.0}"#
    let region = try #require(MonitorPlaceRegion(json: json))
    #expect(region.radius == MonitorDelay.floorRadiusMeters)
}

// MARK: - PlaceTrigger storage round-trip

@Test func placeTriggerRoundTripsThroughStorageFields() throws {
    let region = MonitorPlaceRegion(latitude: 37.33, longitude: -122.03, radius: 150, name: "Office")
    let trigger = PlaceTrigger(region: region, direction: .arrival,
                               delayMinutes: 30, cancelOnContradiction: true)
    let decoded = try #require(PlaceTrigger(
        regionJSON: trigger.regionJSON,
        directionRaw: trigger.direction.rawValue,
        delayMinutes: trigger.delayMinutes,
        cancelOnContradiction: trigger.cancelOnContradiction))
    #expect(decoded == trigger)
}

@Test func placeTriggerInitFailsForMissingOrCorruptPayload() {
    #expect(PlaceTrigger(regionJSON: nil, directionRaw: "arrival",
                         delayMinutes: 0, cancelOnContradiction: true) == nil)
    #expect(PlaceTrigger(regionJSON: "not json", directionRaw: "arrival",
                         delayMinutes: 0, cancelOnContradiction: true) == nil)
    let region = MonitorPlaceRegion(latitude: 1, longitude: 2, radius: 100)
    #expect(PlaceTrigger(regionJSON: region.json, directionRaw: "sideways",
                         delayMinutes: 0, cancelOnContradiction: true) == nil)
}

@Test func placeTriggerDefaultsCancelToTrueAndDelayToZero() throws {
    let region = MonitorPlaceRegion(latitude: 1, longitude: 2, radius: 100)
    let trigger = try #require(PlaceTrigger(
        regionJSON: region.json, directionRaw: "departure",
        delayMinutes: nil, cancelOnContradiction: nil))
    #expect(trigger.delayMinutes == 0)
    #expect(trigger.cancelOnContradiction)
}

// MARK: - BeaconTrigger storage round-trip

@Test func beaconTriggerRoundTripsThroughStorageFields() throws {
    let beacon = MonitorBeaconIdentity(
        uuid: "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0", major: 100, minor: 5, name: "Desk")
    let trigger = BeaconTrigger(beacon: beacon, direction: .arrival,
                                delayMinutes: 0, cancelOnContradiction: false)
    let decoded = try #require(BeaconTrigger(
        beaconJSON: trigger.beaconJSON,
        directionRaw: trigger.direction.rawValue,
        delayMinutes: trigger.delayMinutes,
        cancelOnContradiction: trigger.cancelOnContradiction))
    #expect(decoded == trigger)
    #expect(decoded.beacon.major == 100)
    #expect(decoded.beacon.minor == 5)
}

@Test func beaconTriggerInitFailsForMissingUUIDOrPayload() {
    #expect(BeaconTrigger(beaconJSON: nil, directionRaw: "arrival",
                          delayMinutes: 0, cancelOnContradiction: true) == nil)
    let empty = MonitorBeaconIdentity(uuid: "")
    #expect(BeaconTrigger(beaconJSON: empty.json, directionRaw: "arrival",
                          delayMinutes: 0, cancelOnContradiction: true) == nil)
}

// MARK: - Delay preset clamping

@Test func nearestAllowedMinutesSnapsToOfferedPreset() {
    // Exact presets pass through unchanged.
    for preset in MonitorDelay.allowedMinutes {
        #expect(MonitorDelay.nearestAllowedMinutes(preset) == preset)
    }
    // Off-list values (corrupt/hand-edited import) snap to the closest preset,
    // so the editor Picker always has a matching tag.
    #expect(MonitorDelay.nearestAllowedMinutes(3) == 5)
    #expect(MonitorDelay.nearestAllowedMinutes(7) == 5)
    #expect(MonitorDelay.nearestAllowedMinutes(12) == 10)
    #expect(MonitorDelay.nearestAllowedMinutes(45) == 30)
    #expect(MonitorDelay.nearestAllowedMinutes(-100) == 0)
    #expect(MonitorDelay.nearestAllowedMinutes(9_999) == 60)
}
