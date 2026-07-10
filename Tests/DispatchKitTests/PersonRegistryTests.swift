import Foundation
import SwiftData
import Testing
@testable import DispatchKit

// MARK: - Helpers

private func makeContext() throws -> ModelContext {
    ModelContext(try DispatchStore.inMemoryContainer())
}

private func makePerson(_ text: String, alternates: [String] = [],
                        usage: Int = 0, questions: Int = 0) -> PersonEntity {
    let person = PersonEntity()
    person.text = text
    person.alternateNames = alternates
    person.usageCount = usage
    person.questionCount = questions
    return person
}

/// Inserts a people question + a report with one people response per name list.
private func seedPeopleResponses(_ nameLists: [[String]], prompt: String = "Who are you with?",
                                 in context: ModelContext) {
    let question = Question()
    question.uniqueIdentifier = "q-people"
    question.prompt = prompt
    question.typeRaw = QuestionType.people.rawValue
    context.insert(question)
    for (index, names) in nameLists.enumerated() {
        let report = Report()
        report.uniqueIdentifier = "r-\(index)"
        let response = Response()
        response.uniqueIdentifier = "resp-\(index)"
        response.questionPrompt = prompt
        response.questionIdentifier = "q-people"
        response.tokens = names.map { TokenValue(text: $0) }
        response.report = report
        context.insert(report)
    }
}

// MARK: - Model defaults

@Test func personEntityGainsDefaultedRegistryFields() throws {
    let context = try makeContext()
    let person = makePerson("Alex")
    context.insert(person)
    try context.save()

    let fetched = try #require(try context.fetch(FetchDescriptor<PersonEntity>()).first)
    #expect(!fetched.uniqueIdentifier.isEmpty)
    #expect(UUID(uuidString: fetched.uniqueIdentifier) != nil)
    #expect(fetched.alternateNames.isEmpty)

    // Identifiers are unique per row.
    let other = makePerson("Sam")
    #expect(other.uniqueIdentifier != person.uniqueIdentifier)
}

// MARK: - Resolution

@Test func resolvesByDisplayNameCaseAndDiacriticInsensitively() {
    let people = [makePerson("José García"), makePerson("Alex")]
    #expect(PersonResolver.person(matching: "jose garcia", in: people) === people[0])
    #expect(PersonResolver.person(matching: "ALEX", in: people) === people[1])
    #expect(PersonResolver.person(matching: "Álex", in: people) === people[1])
    #expect(PersonResolver.person(matching: "Nobody", in: people) == nil)
    #expect(PersonResolver.person(matching: "  ", in: people) == nil)
}

@Test func resolvesByAlternateNames() {
    let person = makePerson("Robert", alternates: ["Bob", "Bobby"])
    #expect(PersonResolver.person(matching: "bob", in: [person]) === person)
    #expect(PersonResolver.person(matching: "BOBBY", in: [person]) === person)
    #expect(PersonResolver.person(matching: "Rob", in: [person]) == nil)
}

// MARK: - Rename healing

@Test func renameMovesOldNameIntoAlternates() {
    let person = makePerson("Bob", usage: 3)
    PersonResolver.rename(person, to: "Robert")
    #expect(person.text == "Robert")
    #expect(person.alternateNames == ["Bob"])
    // Still resolves under both names.
    #expect(PersonResolver.person(matching: "bob", in: [person]) === person)
    #expect(PersonResolver.person(matching: "robert", in: [person]) === person)
}

@Test func renameToExistingAliasDoesNotDuplicate() {
    let person = makePerson("Robert", alternates: ["Bob"])
    // Rename to the alias: "Robert" joins alternates, "Bob" leaves (it is
    // now the display name) — no duplicates in any case form.
    PersonResolver.rename(person, to: "Bob")
    #expect(person.text == "Bob")
    #expect(person.alternateNames == ["Robert"])

    // Rename back and forth never accretes duplicates.
    PersonResolver.rename(person, to: "Robert")
    PersonResolver.rename(person, to: "Bob")
    #expect(person.alternateNames == ["Robert"])
}

@Test func renameIgnoresEmptyNewName() {
    let person = makePerson("Alex")
    PersonResolver.rename(person, to: "   ")
    #expect(person.text == "Alex")
    #expect(person.alternateNames.isEmpty)
}

// MARK: - Merge

@Test func mergeUnionsNamesSumsCountsAndDeletesAbsorbed() throws {
    let context = try makeContext()
    let survivor = makePerson("Robert", alternates: ["Bob"], usage: 5, questions: 2)
    let absorbed = makePerson("Bobby", alternates: ["Bobster", "bob"], usage: 3, questions: 1)
    context.insert(survivor)
    context.insert(absorbed)
    try context.save()

    try PersonResolver.merge(absorbed, into: survivor, context: context)

    let remaining = try context.fetch(FetchDescriptor<PersonEntity>())
    #expect(remaining.count == 1)
    #expect(survivor.text == "Robert")
    // "bob" dropped (case-insensitive dup of "Bob"); order preserved.
    #expect(survivor.alternateNames == ["Bob", "Bobby", "Bobster"])
    #expect(survivor.usageCount == 8)
    #expect(survivor.questionCount == 2)
    // Everything the absorbed person answered as now resolves to the survivor.
    #expect(PersonResolver.person(matching: "bobster", in: remaining) === survivor)
}

// MARK: - VocabularyBuilder rebuild preservation (the delicate one)

@Test func rebuildPreservesRegistryFieldsAndUpdatesCountsInPlace() throws {
    let context = try makeContext()
    seedPeopleResponses([["Bob"], ["Robert"], ["Robert", "Alex"]], in: context)
    // Pre-existing registry entity: renamed Bob → Robert.
    let robert = makePerson("Robert", alternates: ["Bob"], usage: 99, questions: 9)
    let robertID = robert.uniqueIdentifier
    context.insert(robert)
    try context.save()

    try VocabularyBuilder.rebuild(in: context)

    let people = try context.fetch(FetchDescriptor<PersonEntity>())
    #expect(people.count == 2)
    let rebuiltRobert = try #require(people.first { $0.text == "Robert" })
    // Same row, same identity, aliases intact — counts recomputed across
    // BOTH the display name and alternate-name usages (1 Bob + 2 Robert).
    #expect(rebuiltRobert.uniqueIdentifier == robertID)
    #expect(rebuiltRobert.alternateNames == ["Bob"])
    #expect(rebuiltRobert.usageCount == 3)
    #expect(rebuiltRobert.questionCount == 1)
    // Genuinely new name got a fresh plain entry.
    let alex = try #require(people.first { $0.text == "Alex" })
    #expect(alex.usageCount == 1)
    #expect(alex.alternateNames.isEmpty)
}

@Test func rebuildKeepsAliasedRegistryEntriesAtZeroUsage() throws {
    let context = try makeContext()
    seedPeopleResponses([["Alex"]], in: context)
    // Registry entry whose names appear in NO current response.
    let ghost = makePerson("Casper", alternates: ["Ghost"], usage: 7, questions: 3)
    context.insert(ghost)
    // Plain derived entry with no aliases and no matching usage: deletable.
    let stale = makePerson("Stale", usage: 4, questions: 1)
    context.insert(stale)
    try context.save()

    try VocabularyBuilder.rebuild(in: context)

    let people = try context.fetch(FetchDescriptor<PersonEntity>())
    #expect(Set(people.map(\.text)) == ["Alex", "Casper"])
    let casper = try #require(people.first { $0.text == "Casper" })
    #expect(casper.alternateNames == ["Ghost"])
    #expect(casper.usageCount == 0)
    #expect(casper.questionCount == 0)
}

@Test func rebuildIsIdempotentForRegistryEntries() throws {
    let context = try makeContext()
    seedPeopleResponses([["Bob"], ["Robert"]], in: context)
    let robert = makePerson("Robert", alternates: ["Bob"])
    let robertID = robert.uniqueIdentifier
    context.insert(robert)
    try context.save()

    try VocabularyBuilder.rebuild(in: context)
    try VocabularyBuilder.rebuild(in: context)

    let people = try context.fetch(FetchDescriptor<PersonEntity>())
    #expect(people.count == 1)
    #expect(people.first?.uniqueIdentifier == robertID)
    #expect(people.first?.usageCount == 2)
}

@Test func rebuildTokenBehaviorUnchangedByRegistry() throws {
    let context = try makeContext()
    let question = Question()
    question.uniqueIdentifier = "q-tokens"
    question.prompt = "What are you doing?"
    question.typeRaw = QuestionType.tokens.rawValue
    context.insert(question)
    let report = Report()
    report.uniqueIdentifier = "r-t"
    let response = Response()
    response.uniqueIdentifier = "resp-t"
    response.questionPrompt = question.prompt
    response.questionIdentifier = question.uniqueIdentifier
    response.tokens = [TokenValue(text: "Coding")]
    response.report = report
    context.insert(report)
    // A stale token entity is still delete-all-recreated.
    let stale = TokenEntity()
    stale.text = "Stale"
    stale.usageCount = 9
    context.insert(stale)
    try context.save()

    try VocabularyBuilder.rebuild(in: context)

    let tokens = try context.fetch(FetchDescriptor<TokenEntity>())
    #expect(tokens.map(\.text) == ["Coding"])
    #expect(tokens.first?.usageCount == 1)
}
