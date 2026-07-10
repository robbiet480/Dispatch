import Foundation
import SwiftData
import Testing
@testable import DispatchKit

private func makeContext() throws -> ModelContext {
    ModelContext(try DispatchStore.inMemoryContainer())
}

private func seedFullStore(in context: ModelContext) throws {
    let question = Question()
    question.uniqueIdentifier = "q-1"
    question.prompt = "What are you doing?"
    context.insert(question)

    let report = Report()
    report.uniqueIdentifier = "r-1"
    context.insert(report)
    let response = Response()
    response.report = report
    response.questionIdentifier = "q-1"
    context.insert(response)

    let group = PromptGroup()
    group.uniqueIdentifier = "g-1"
    context.insert(group)

    let token = TokenEntity()
    token.text = "Coding"
    context.insert(token)
    let person = PersonEntity()
    person.text = "Alice"
    context.insert(person)

    try context.save()
}

@Test func deleteAllModelsEmptiesEveryModelAndReportsCounts() throws {
    let context = try makeContext()
    try seedFullStore(in: context)

    let counts = try DeleteAllData.deleteAllModels(in: context)

    #expect(counts.questions == 1)
    #expect(counts.reports == 1)
    #expect(counts.responses == 1)
    #expect(counts.promptGroups == 1)
    #expect(counts.tokens == 1)
    #expect(counts.people == 1)
    #expect(counts.total == 6)

    #expect(try context.fetchCount(FetchDescriptor<Question>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<Report>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<Response>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<PromptGroup>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<TokenEntity>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<PersonEntity>()) == 0)
}

@Test func deleteAllModelsIsNoOpOnEmptyStore() throws {
    let context = try makeContext()
    let counts = try DeleteAllData.deleteAllModels(in: context)
    #expect(counts == DeleteAllData.Counts())
    #expect(counts.total == 0)
}

@Test func reseedAfterDeleteAllRestoresTheDefaultCatalog() throws {
    let context = try makeContext()
    try seedFullStore(in: context)
    try DeleteAllData.deleteAllModels(in: context)

    // The seeder must run against the now-empty store (the delete-all flow
    // depends on this) and produce the frozen deterministic identifiers.
    let seeded = try DefaultQuestions.seedIfEmpty(into: context)
    #expect(seeded == DefaultQuestions.all.count)

    let questions = try context.fetch(FetchDescriptor<Question>())
    #expect(questions.count == DefaultQuestions.all.count)
    let expectedIDs = Set(DefaultQuestions.all.map(\.identifier))
    #expect(Set(questions.map(\.uniqueIdentifier)) == expectedIDs)

    // And it must stay a no-op when the store isn't empty.
    #expect(try DefaultQuestions.seedIfEmpty(into: context) == 0)
    #expect(try context.fetchCount(FetchDescriptor<Question>()) == DefaultQuestions.all.count)
}

@Test func clearedDefaultsKeysCoverDataKeyedStateOnly() throws {
    // Data-keyed runtime state clears...
    #expect(DeleteAllData.clearedDefaultsKeys.contains("lastActedAt"))
    #expect(DeleteAllData.clearedDefaultsKeys.contains(
        VisualizationFilterStore.hiddenQuestionIDsDefaultsKey))
    #expect(DeleteAllData.clearedDefaultsKeys.contains("visualization.filterCriteria"))
    #expect(DeleteAllData.clearedDefaultsKeys.contains("workoutEnd.lastSeenEndDate"))
    #expect(DeleteAllData.clearedDefaultsKeys.contains("visitArrival.lastHandledArrivalDate"))
    #expect(DeleteAllData.clearedAppGroupDefaultsKeys.contains(
        WidgetQuickAnswerMarker.pendingActedAtKey))
    #expect(DeleteAllData.clearedAppGroupDefaultsKeys.contains(
        WidgetQuickAnswerMarker.filedAtKey))
    #expect(DeleteAllData.clearedAppGroupDefaultsKeys.contains("widget.nextPromptDate"))

    // ...while one-time migration markers, onboarding, Focus state, and
    // preference keys are deliberately RETAINED (see the rationale doc on
    // DeleteAllData.retainedDefaultsKeys).
    let cleared = Set(DeleteAllData.clearedDefaultsKeys + DeleteAllData.clearedAppGroupDefaultsKeys)
    for retained in DeleteAllData.retainedDefaultsKeys {
        #expect(!cleared.contains(retained), "\(retained) must survive delete-all")
    }
    #expect(DeleteAllData.retainedDefaultsKeys.contains(OnboardingFlag.key))
    #expect(DeleteAllData.retainedDefaultsKeys.contains(ScheduleStampVersion.defaultsKey))
    #expect(DeleteAllData.retainedDefaultsKeys.contains(DefaultQuestionIDMigration.defaultsFlagKey))
    #expect(DeleteAllData.retainedDefaultsKeys.contains(FocusFilterState.defaultsKey))
}

@Test func clearRuntimeDefaultsRemovesListedKeysAndKeepsTheRest() throws {
    let suiteName = "delete-all-data-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    for key in DeleteAllData.clearedDefaultsKeys { defaults.set("x", forKey: key) }
    for key in DeleteAllData.clearedAppGroupDefaultsKeys { defaults.set("x", forKey: key) }
    for key in DeleteAllData.retainedDefaultsKeys { defaults.set("keep", forKey: key) }

    DeleteAllData.clearRuntimeDefaults(defaults)
    DeleteAllData.clearAppGroupDefaults(defaults)

    for key in DeleteAllData.clearedDefaultsKeys {
        #expect(defaults.object(forKey: key) == nil, "\(key) should be cleared")
    }
    for key in DeleteAllData.clearedAppGroupDefaultsKeys {
        #expect(defaults.object(forKey: key) == nil, "\(key) should be cleared")
    }
    for key in DeleteAllData.retainedDefaultsKeys {
        #expect(defaults.string(forKey: key) == "keep", "\(key) should be retained")
    }
}
