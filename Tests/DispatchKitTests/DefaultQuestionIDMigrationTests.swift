import Foundation
import SwiftData
import Testing
@testable import DispatchKit

private func freshDefaults() -> UserDefaults {
    let suite = "migration-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@Test func migrationRewritesEveryReference() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let defaults = freshDefaults()

    for (index, seed) in DefaultQuestions.all.enumerated() {
        let question = Question()
        question.uniqueIdentifier = "default-question-\(index)"
        question.prompt = seed.prompt
        question.type = seed.type
        question.sortOrder = index
        context.insert(question)
    }

    let report = Report()
    report.uniqueIdentifier = "rep-1"
    context.insert(report)

    let response = Response()
    response.uniqueIdentifier = "resp-1"
    response.questionIdentifier = "default-question-1"
    response.report = report
    context.insert(response)

    let otherResponse = Response()
    otherResponse.uniqueIdentifier = "resp-2"
    otherResponse.questionIdentifier = "custom-question"
    otherResponse.report = report
    context.insert(otherResponse)

    let group = PromptGroup()
    group.questionIDs = ["default-question-0", "custom-question", "default-question-3"]
    context.insert(group)
    try context.save()

    defaults.set(["default-question-5", "some-other-id"],
                 forKey: VisualizationFilterStore.hiddenQuestionIDsDefaultsKey)

    let summary = try #require(try DefaultQuestionIDMigration.runIfNeeded(context: context, defaults: defaults))
    #expect(summary.questions == 7)
    #expect(summary.responses == 1)
    #expect(summary.promptGroupReferences == 2)
    #expect(summary.hiddenVisualizationIDs == 1)

    let questions = try context.fetch(FetchDescriptor<Question>())
        .sorted { $0.sortOrder < $1.sortOrder }
    for (index, question) in questions.enumerated() {
        #expect(question.uniqueIdentifier == DefaultQuestions.all[index].identifier)
    }

    let responses = try context.fetch(FetchDescriptor<Response>())
    #expect(responses.first { $0.uniqueIdentifier == "resp-1" }?.questionIdentifier
        == DefaultQuestions.all[1].identifier)
    #expect(responses.first { $0.uniqueIdentifier == "resp-2" }?.questionIdentifier == "custom-question")

    let groups = try context.fetch(FetchDescriptor<PromptGroup>())
    #expect(groups.first?.questionIDs == [
        DefaultQuestions.all[0].identifier,
        "custom-question",
        DefaultQuestions.all[3].identifier,
    ])

    #expect(defaults.stringArray(forKey: VisualizationFilterStore.hiddenQuestionIDsDefaultsKey)
        == [DefaultQuestions.all[5].identifier, "some-other-id"])
    #expect(defaults.bool(forKey: DefaultQuestionIDMigration.defaultsFlagKey))
}

@Test func migrationIsIdempotent() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let defaults = freshDefaults()

    let question = Question()
    question.uniqueIdentifier = "default-question-2"
    context.insert(question)
    try context.save()

    let first = try #require(try DefaultQuestionIDMigration.runIfNeeded(context: context, defaults: defaults))
    #expect(first.questions == 1)

    // Second run is a no-op: flag guard short-circuits before any fetch.
    let second = try DefaultQuestionIDMigration.runIfNeeded(context: context, defaults: defaults)
    #expect(second == nil)
    let questions = try context.fetch(FetchDescriptor<Question>())
    #expect(questions.first?.uniqueIdentifier == DefaultQuestions.all[2].identifier)
}

@Test func migrationLeavesNonDefaultIDsUntouched() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let defaults = freshDefaults()

    let custom = Question()
    let customID = UUID().uuidString
    custom.uniqueIdentifier = customID
    context.insert(custom)

    let outOfRange = Question()
    outOfRange.uniqueIdentifier = "default-question-42"
    context.insert(outOfRange)
    try context.save()

    let summary = try #require(try DefaultQuestionIDMigration.runIfNeeded(context: context, defaults: defaults))
    #expect(summary.total == 0)
    #expect(defaults.bool(forKey: DefaultQuestionIDMigration.defaultsFlagKey))

    let ids = try context.fetch(FetchDescriptor<Question>()).map(\.uniqueIdentifier)
    #expect(Set(ids) == [customID, "default-question-42"])
}

@Test func migrationToleratesDanglingReferences() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let defaults = freshDefaults()

    // No Question rows at all — the response and group point at a deleted
    // legacy question. Rewrite proceeds via the frozen N → slug table.
    let report = Report()
    report.uniqueIdentifier = "rep-dangling"
    context.insert(report)

    let response = Response()
    response.uniqueIdentifier = "resp-dangling"
    response.questionIdentifier = "default-question-4"
    response.report = report
    context.insert(response)

    let group = PromptGroup()
    group.questionIDs = ["default-question-6"]
    context.insert(group)
    try context.save()

    let summary = try #require(try DefaultQuestionIDMigration.runIfNeeded(context: context, defaults: defaults))
    #expect(summary.questions == 0)
    #expect(summary.responses == 1)
    #expect(summary.promptGroupReferences == 1)

    let responses = try context.fetch(FetchDescriptor<Response>())
    #expect(responses.first?.questionIdentifier == DefaultQuestions.all[4].identifier)
    let groups = try context.fetch(FetchDescriptor<PromptGroup>())
    #expect(groups.first?.questionIDs == [DefaultQuestions.all[6].identifier])
}

@Test func migrationSkipsWhenFlagAlreadySet() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let defaults = freshDefaults()
    defaults.set(true, forKey: DefaultQuestionIDMigration.defaultsFlagKey)

    let question = Question()
    question.uniqueIdentifier = "default-question-0"
    context.insert(question)
    try context.save()

    #expect(try DefaultQuestionIDMigration.runIfNeeded(context: context, defaults: defaults) == nil)
    let questions = try context.fetch(FetchDescriptor<Question>())
    #expect(questions.first?.uniqueIdentifier == "default-question-0")
}
