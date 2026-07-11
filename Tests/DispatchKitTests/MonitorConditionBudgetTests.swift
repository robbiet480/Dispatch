import Testing
@testable import DispatchKit

@Test func underLimitRegistersAll() {
    let ids = ["a", "b", "c"]
    let result = MonitorConditionBudget.allocate(groupIDs: ids, limit: 20)
    #expect(result.registered == ids)
    #expect(result.dropped.isEmpty)
}

@Test func overLimitRegistersPriorityPrefixAndDropsRest() {
    let ids = (1...25).map { "g\($0)" }
    let result = MonitorConditionBudget.allocate(groupIDs: ids, limit: 20)
    #expect(result.registered == Array(ids.prefix(20)))
    #expect(result.dropped == Array(ids.suffix(5)))
}

@Test func zeroLimitDropsEverything() {
    let result = MonitorConditionBudget.allocate(groupIDs: ["a", "b"], limit: 0)
    #expect(result.registered.isEmpty)
    #expect(result.dropped == ["a", "b"])
}

@Test func emptyInputYieldsEmpty() {
    let result = MonitorConditionBudget.allocate(groupIDs: [], limit: 20)
    #expect(result.registered.isEmpty)
    #expect(result.dropped.isEmpty)
}

@Test func defaultLimitIsTwenty() {
    #expect(MonitorConditionBudget.defaultLimit == 20)
}
