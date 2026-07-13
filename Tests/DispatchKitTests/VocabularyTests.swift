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
    // People-type responses: "Alex" (q-people, snap-3).
    #expect(people.map(\.text) == ["Alex"])

    // Rebuild is idempotent (no duplicate rows).
    try VocabularyBuilder.rebuild(in: context)
    #expect(try context.fetch(FetchDescriptor<TokenEntity>()).count == 2)
}

/// Regression (Mac-not-syncing / "Last iCloud export - failed", Angela): a
/// rebuild whose inputs are unchanged must NOT mutate the store. The shipped
/// `rebuild` deletes every TokenEntity/PersonEntity row and re-inserts them
/// unconditionally, so each pass recreates every row with a fresh identity and
/// `save()`s. Under CloudKit that posts `NSPersistentStoreRemoteChange` for our
/// own save, which reschedules `RemoteChangeObserver`'s pipeline every 2s (an
/// infinite loop — the "Dedupe pass every 2 seconds" seen on-device) AND churns
/// the entire vocabulary's CKRecords forever, thrashing export so the Mac never
/// receives a stable snapshot. A steady-state rebuild must be a true no-op:
/// same rows, same identities, nothing to export.
@Test func rebuildDoesNotChurnRowsWhenInputsUnchanged() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)

    let firstChanged = try VocabularyBuilder.rebuild(in: context)
    #expect(firstChanged, "first rebuild over fresh import should create vocabulary")
    try context.save()
    let tokenIDsBefore = Set(try context.fetch(FetchDescriptor<TokenEntity>()).map(\.persistentModelID))
    let personIDsBefore = Set(try context.fetch(FetchDescriptor<PersonEntity>()).map(\.persistentModelID))

    // Second rebuild over identical data: must be a true no-op — reuse the
    // existing rows (stable identities ⇒ no CKRecord churn) and report that it
    // changed nothing (⇒ no save ⇒ no NSPersistentStoreRemoteChange ⇒ the
    // RemoteChangeObserver 2s loop cannot sustain).
    let secondChanged = try VocabularyBuilder.rebuild(in: context)
    let tokenIDsAfter = Set(try context.fetch(FetchDescriptor<TokenEntity>()).map(\.persistentModelID))
    let personIDsAfter = Set(try context.fetch(FetchDescriptor<PersonEntity>()).map(\.persistentModelID))

    #expect(!secondChanged, "unchanged rebuild reported a change — it would save and re-trigger the sync loop")
    #expect(tokenIDsAfter == tokenIDsBefore, "rebuild recreated token rows — this is the CloudKit export loop")
    #expect(personIDsAfter == personIDsBefore, "rebuild recreated person rows — this is the CloudKit export loop")
}
