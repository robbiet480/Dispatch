import Foundation
import SwiftData
import Testing
@testable import DispatchKit

@Test func rebuildsVocabularyFromResponses() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)

    try VocabularyBuilder.rebuild(in: context)

    let tokens = try context.fetch(FetchDescriptor<TokenEntity>())
    // Token-type responses in fixture: "Working", "Coding" (q-tokens).
    #expect(Set(tokens.map(\.text)) == ["Working", "Coding"])
    #expect(tokens.first { $0.text == "Working" }?.usageCount == 1)
    #expect(tokens.first { $0.text == "Working" }?.questionCount == 1)

    let people = try context.fetch(FetchDescriptor<PersonEntity>())
    // People-type responses: "Melissa" (q-people, snap-3).
    #expect(people.map(\.text) == ["Melissa"])

    // Rebuild is idempotent (no duplicate rows).
    try VocabularyBuilder.rebuild(in: context)
    #expect(try context.fetch(FetchDescriptor<TokenEntity>()).count == 2)
}
