import Foundation
import Testing
@testable import DispatchKit

private func group(id: String) -> PromptGroup {
    let g = PromptGroup()
    g.uniqueIdentifier = id
    return g
}

// MARK: - Plan filtering

@Test func nilStatePlansEverything() {
    let groups = [group(id: "a"), group(id: "b")]
    let result = FocusFilterState.filterPlan(groups: groups, state: nil)
    #expect(result.groups.map(\.uniqueIdentifier) == ["a", "b"])
    #expect(result.planGlobal)
}

@Test func activeStatePlansOnlyAllowedSubsetInOrder() {
    let groups = [group(id: "a"), group(id: "b"), group(id: "c")]
    let state = FocusFilterState(label: "Work", allowedGroupIDs: ["c", "a"], pauseGlobal: false)
    let result = FocusFilterState.filterPlan(groups: groups, state: state)
    // Input (sortOrder) order is preserved — the budget allocator depends on it.
    #expect(result.groups.map(\.uniqueIdentifier) == ["a", "c"])
    #expect(result.planGlobal)
}

@Test func pauseGlobalTurnsOffGlobalPlanning() {
    let state = FocusFilterState(label: "Work", allowedGroupIDs: ["a"], pauseGlobal: true)
    let result = FocusFilterState.filterPlan(groups: [group(id: "a")], state: state)
    #expect(result.groups.map(\.uniqueIdentifier) == ["a"])
    #expect(!result.planGlobal)
    #expect(!state.allowsGlobal)
}

@Test func emptyAllowedSetMutesAllGroupsGlobalPerFlag() {
    let groups = [group(id: "a"), group(id: "b")]
    let muted = FocusFilterState(label: "Sleep", allowedGroupIDs: [], pauseGlobal: false)
    let mutedResult = FocusFilterState.filterPlan(groups: groups, state: muted)
    #expect(mutedResult.groups.isEmpty)
    #expect(mutedResult.planGlobal)

    let silent = FocusFilterState(label: "Sleep", allowedGroupIDs: [], pauseGlobal: true)
    let silentResult = FocusFilterState.filterPlan(groups: groups, state: silent)
    #expect(silentResult.groups.isEmpty)
    #expect(!silentResult.planGlobal)
}

@Test func allowsMatchesMembership() {
    let state = FocusFilterState(label: "Work", allowedGroupIDs: ["a"], pauseGlobal: false)
    #expect(state.allows(groupID: "a"))
    #expect(!state.allows(groupID: "b"))
}

// nil allowedGroupIDs = name-only filter (named Focus capture with no
// group restriction) — distinct from [] (mute every group).
@Test func nilAllowedSetRestrictsNothing() {
    let groups = [group(id: "a"), group(id: "b")]
    let nameOnly = FocusFilterState(label: "Work", allowedGroupIDs: nil, pauseGlobal: false)
    #expect(nameOnly.allows(groupID: "a"))
    #expect(nameOnly.allows(groupID: "anything"))
    let result = FocusFilterState.filterPlan(groups: groups, state: nameOnly)
    #expect(result.groups.map(\.uniqueIdentifier) == ["a", "b"])
    #expect(result.planGlobal)

    // Global pause still applies independently of the nil allowed set.
    let paused = FocusFilterState(label: "Work", allowedGroupIDs: nil, pauseGlobal: true)
    let pausedResult = FocusFilterState.filterPlan(groups: groups, state: paused)
    #expect(pausedResult.groups.map(\.uniqueIdentifier) == ["a", "b"])
    #expect(!pausedResult.planGlobal)
}

// MARK: - Persistence

@Test func roundTripsThroughDefaults() throws {
    let suiteName = "focus-filter-state-tests"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(FocusFilterState.read(from: defaults) == nil)
    #expect(!FocusFilterState.isActive(in: defaults))

    let activatedAt = Date(timeIntervalSince1970: 1_780_000_000)
    let state = FocusFilterState(
        label: "Work", allowedGroupIDs: ["a", "b"], pauseGlobal: true, activatedAt: activatedAt
    )
    state.write(to: defaults)
    #expect(FocusFilterState.read(from: defaults) == state)
    #expect(FocusFilterState.isActive(in: defaults))

    FocusFilterState.clear(in: defaults)
    #expect(FocusFilterState.read(from: defaults) == nil)
    #expect(!FocusFilterState.isActive(in: defaults))

    // nil allowedGroupIDs survives the round trip (nil-vs-empty is
    // load-bearing: nil ⇒ all groups allowed, [] ⇒ mute all).
    let nameOnly = FocusFilterState(
        label: "Gym", allowedGroupIDs: nil, pauseGlobal: false, activatedAt: activatedAt
    )
    nameOnly.write(to: defaults)
    let readBack = FocusFilterState.read(from: defaults)
    #expect(readBack == nameOnly)
    #expect(readBack?.allowedGroupIDs == nil)
    FocusFilterState.clear(in: defaults)
}

@Test func corruptBlobFailsOpenToNoFilter() throws {
    let suiteName = "focus-filter-state-corrupt-tests"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(Data("not json".utf8), forKey: FocusFilterState.defaultsKey)
    #expect(FocusFilterState.read(from: defaults) == nil)
    #expect(!FocusFilterState.isActive(in: defaults))
}

// MARK: - indicatesSleep (plan 39, Signal 1)

// (a) A filter marked as a sleep signal round-trips the flag through defaults.
@Test func indicatesSleepRoundTripsThroughDefaults() throws {
    let suiteName = "focus-filter-state-sleep-tests"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let state = FocusFilterState(
        label: "Sleep", allowedGroupIDs: [], pauseGlobal: true, indicatesSleep: true
    )
    state.write(to: defaults)
    let readBack = FocusFilterState.read(from: defaults)
    #expect(readBack == state)
    #expect(readBack?.indicatesSleep == true)
}

// (b) LENIENCY — a verbatim old-format blob (no indicatesSleep key) decodes
// with indicatesSleep == nil. The fail-open contract is untouched: old
// persisted blobs and processes running old code decode unchanged.
@Test func oldBlobWithoutSleepKeyDecodesAsNil() throws {
    let suiteName = "focus-filter-state-legacy-tests"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // Verbatim pre-plan-39 JSON, NOT re-encoded (activatedAt is a Date encoded
    // as a reference-date Double by JSONEncoder's default strategy).
    let legacy = #"{"label":"Work","allowedGroupIDs":["a","b"],"pauseGlobal":false,"activatedAt":760000000}"#
    defaults.set(Data(legacy.utf8), forKey: FocusFilterState.defaultsKey)

    let readBack = try #require(FocusFilterState.read(from: defaults))
    #expect(readBack.indicatesSleep == nil)
    #expect(readBack.label == "Work")
    #expect(readBack.allowedGroupIDs == ["a", "b"])
}

// (c) filterPlan output is unaffected by the sleep flag — it only gates the
// awake-state signal, never the schedule.
@Test func indicatesSleepDoesNotAffectFilterPlan() {
    let groups = [group(id: "a"), group(id: "b")]
    let marker = FocusFilterState(
        label: "Sleep", allowedGroupIDs: ["a"], pauseGlobal: false, indicatesSleep: true
    )
    let plain = FocusFilterState(
        label: "Sleep", allowedGroupIDs: ["a"], pauseGlobal: false, indicatesSleep: nil
    )
    let markerResult = FocusFilterState.filterPlan(groups: groups, state: marker)
    let plainResult = FocusFilterState.filterPlan(groups: groups, state: plain)
    #expect(markerResult.groups.map(\.uniqueIdentifier) == plainResult.groups.map(\.uniqueIdentifier))
    #expect(markerResult.planGlobal == plainResult.planGlobal)
}
