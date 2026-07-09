import Foundation
import SwiftData
import Testing
@testable import DispatchKit

private func makeContext() throws -> ModelContext {
    ModelContext(try DispatchStore.inMemoryContainer())
}

private func makeQuestion(id: String, prompt: String, in context: ModelContext) -> Question {
    let question = Question()
    question.uniqueIdentifier = id
    question.prompt = prompt
    context.insert(question)
    return question
}

@Test func dedupeIsNoOpOnCleanStore() throws {
    let context = try makeContext()
    _ = makeQuestion(id: "q-1", prompt: "One", in: context)
    _ = makeQuestion(id: "q-2", prompt: "Two", in: context)
    let group = PromptGroup()
    group.uniqueIdentifier = "g-1"
    context.insert(group)
    let report = Report()
    report.uniqueIdentifier = "r-1"
    context.insert(report)
    let token = TokenEntity()
    token.text = "Coding"
    token.usageCount = 3
    context.insert(token)
    try context.save()

    let summary = try SyncDedupe.run(in: context)

    #expect(summary == DedupeSummary())
    #expect(summary.totalRemoved == 0)
    #expect(try context.fetchCount(FetchDescriptor<Question>()) == 2)
    #expect(try context.fetchCount(FetchDescriptor<PromptGroup>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<Report>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<TokenEntity>()) == 1)
}

@Test func dedupesQuestionsByUniqueIdentifier() throws {
    let context = try makeContext()
    _ = makeQuestion(id: "q-dup", prompt: "What are you doing?", in: context)
    _ = makeQuestion(id: "q-dup", prompt: "What are you doing?", in: context)
    _ = makeQuestion(id: "q-dup", prompt: "What are you doing?", in: context)
    _ = makeQuestion(id: "q-other", prompt: "Who are you with?", in: context)
    try context.save()

    let summary = try SyncDedupe.run(in: context)

    #expect(summary.questionsRemoved == 2)
    let remaining = try context.fetch(FetchDescriptor<Question>())
    #expect(remaining.count == 2)
    #expect(remaining.filter { $0.uniqueIdentifier == "q-dup" }.count == 1)
}

@Test func dedupesPromptGroupsByUniqueIdentifier() throws {
    let context = try makeContext()
    for _ in 0..<2 {
        let group = PromptGroup()
        group.uniqueIdentifier = "g-dup"
        group.name = "Workday"
        context.insert(group)
    }
    try context.save()

    let summary = try SyncDedupe.run(in: context)

    #expect(summary.promptGroupsRemoved == 1)
    #expect(try context.fetchCount(FetchDescriptor<PromptGroup>()) == 1)
}

@Test func dedupesReportsAndCascadesResponses() throws {
    let context = try makeContext()
    for _ in 0..<2 {
        let report = Report()
        report.uniqueIdentifier = "r-dup"
        let response = Response()
        response.questionPrompt = "What are you doing?"
        report.responses = [response]
        context.insert(report)
    }
    try context.save()
    #expect(try context.fetchCount(FetchDescriptor<Response>()) == 2)

    let summary = try SyncDedupe.run(in: context)

    #expect(summary.reportsRemoved == 1)
    #expect(try context.fetchCount(FetchDescriptor<Report>()) == 1)
    // Cascade delete removed the extra report's responses too.
    #expect(try context.fetchCount(FetchDescriptor<Response>()) == 1)
}

@Test func mergesTokensSummingUsageCounts() throws {
    let context = try makeContext()
    let first = TokenEntity()
    first.text = "Coding"
    first.usageCount = 3
    first.questionCount = 1
    context.insert(first)
    let second = TokenEntity()
    second.text = "Coding"
    second.usageCount = 5
    second.questionCount = 2
    context.insert(second)
    try context.save()

    let summary = try SyncDedupe.run(in: context)

    #expect(summary.tokensRemoved == 1)
    let tokens = try context.fetch(FetchDescriptor<TokenEntity>())
    #expect(tokens.count == 1)
    #expect(tokens.first?.usageCount == 8)
    #expect(tokens.first?.questionCount == 2)
}

@Test func mergesPeopleSummingUsageCounts() throws {
    let context = try makeContext()
    for count in [2, 4] {
        let person = PersonEntity()
        person.text = "Alex"
        person.usageCount = count
        person.questionCount = 1
        context.insert(person)
    }
    try context.save()

    let summary = try SyncDedupe.run(in: context)

    #expect(summary.peopleRemoved == 1)
    let people = try context.fetch(FetchDescriptor<PersonEntity>())
    #expect(people.count == 1)
    #expect(people.first?.usageCount == 6)
}

@Test func survivorChoiceIsDeterministic() throws {
    // The survivor is a deterministic function of the store contents: the
    // duplicate with the lowest encoded persistent identifier. (Insertion
    // order is NOT the rule — encoded IDs embed per-store identifiers, so
    // the pick can differ between stores, but never within one.)
    for _ in 0..<5 {
        let context = try makeContext()
        let first = makeQuestion(id: "q-dup", prompt: "A", in: context)
        let second = makeQuestion(id: "q-dup", prompt: "B", in: context)
        try context.save()

        let expectedSurvivor = [first, second]
            .min { SyncDedupe.persistentIDString($0) < SyncDedupe.persistentIDString($1) }!
            .prompt

        _ = try SyncDedupe.run(in: context)
        let remaining = try context.fetch(FetchDescriptor<Question>())
        #expect(remaining.count == 1)
        #expect(remaining[0].prompt == expectedSurvivor)

        // Second pass is a no-op: the pass converged.
        let again = try SyncDedupe.run(in: context)
        #expect(again.totalRemoved == 0)
    }
}

@Test func summaryCountsAllTypesInOnePass() throws {
    let context = try makeContext()
    _ = makeQuestion(id: "q-dup", prompt: "Dup", in: context)
    _ = makeQuestion(id: "q-dup", prompt: "Dup", in: context)
    for _ in 0..<3 {
        let group = PromptGroup()
        group.uniqueIdentifier = "g-dup"
        context.insert(group)
    }
    for _ in 0..<2 {
        let report = Report()
        report.uniqueIdentifier = "r-dup"
        context.insert(report)
    }
    for _ in 0..<2 {
        let token = TokenEntity()
        token.text = "Coding"
        context.insert(token)
    }
    for _ in 0..<2 {
        let person = PersonEntity()
        person.text = "Alex"
        context.insert(person)
    }
    try context.save()

    let summary = try SyncDedupe.run(in: context)

    #expect(summary.questionsRemoved == 1)
    #expect(summary.promptGroupsRemoved == 2)
    #expect(summary.reportsRemoved == 1)
    #expect(summary.tokensRemoved == 1)
    #expect(summary.peopleRemoved == 1)
    #expect(summary.totalRemoved == 6)
}
