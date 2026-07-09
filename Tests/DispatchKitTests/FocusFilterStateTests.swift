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
