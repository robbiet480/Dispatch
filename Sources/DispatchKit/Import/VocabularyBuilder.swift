import Foundation
import SwiftData

public enum VocabularyBuilder {
    /// Rebuilds token/person vocabularies from all stored responses.
    /// People-type questions feed PersonEntity; token-type feed TokenEntity.
    public static func rebuild(in context: ModelContext) throws {
        let questions = try context.fetch(FetchDescriptor<Question>())
        let typeByPrompt = Dictionary(questions.map { ($0.prompt, $0.type) },
                                      uniquingKeysWith: { first, _ in first })
        let responses = try context.fetch(FetchDescriptor<Response>())

        struct Tally { var uses = 0; var prompts = Set<String>() }
        var tokenTally: [String: Tally] = [:]
        var personTally: [String: Tally] = [:]

        for response in responses {
            guard let values = response.tokens, !values.isEmpty else { continue }
            let isPeople = typeByPrompt[response.questionPrompt] == .people
            for value in values {
                var tally = (isPeople ? personTally : tokenTally)[value.text] ?? Tally()
                tally.uses += 1
                tally.prompts.insert(response.questionPrompt)
                if isPeople { personTally[value.text] = tally } else { tokenTally[value.text] = tally }
            }
        }

        try context.delete(model: TokenEntity.self)
        for (text, tally) in tokenTally {
            let entity = TokenEntity()
            entity.text = text
            entity.usageCount = tally.uses
            entity.questionCount = tally.prompts.count
            context.insert(entity)
        }

        // People are the person REGISTRY (plan 22): registry fields
        // (uniqueIdentifier, alternateNames) must survive a rebuild, so
        // instead of delete-all-recreate we match existing entities by text
        // OR alternate names and update counts in place. Only entities that
        // match no current usage AND carry no alternate names are deleted —
        // registry entries with aliases survive even at zero usage.
        let fetchedPeople = try context.fetch(FetchDescriptor<PersonEntity>())
        backfillSharedIdentifiers(fetchedPeople)
        let existingPeople = fetchedPeople
            .sorted { $0.uniqueIdentifier < $1.uniqueIdentifier }
        var tallies: [ObjectIdentifier: Tally] = [:]
        var unmatched: [(text: String, tally: Tally)] = []
        for (text, tally) in personTally.sorted(by: { $0.key < $1.key }) {
            if let person = PersonResolver.person(matching: text, in: existingPeople) {
                var merged = tallies[ObjectIdentifier(person)] ?? Tally()
                merged.uses += tally.uses
                merged.prompts.formUnion(tally.prompts)
                tallies[ObjectIdentifier(person)] = merged
            } else {
                unmatched.append((text, tally))
            }
        }
        for person in existingPeople {
            if let tally = tallies[ObjectIdentifier(person)] {
                person.usageCount = tally.uses
                person.questionCount = tally.prompts.count
            } else if person.alternateNames.isEmpty {
                context.delete(person)
            } else {
                person.usageCount = 0
                person.questionCount = 0
            }
        }
        for (text, tally) in unmatched {
            let entity = PersonEntity()
            entity.text = text
            entity.usageCount = tally.uses
            entity.questionCount = tally.prompts.count
            context.insert(entity)
        }
        try context.save()
    }

    /// One-time backfill for the SwiftData lightweight-migration trap: the
    /// `uniqueIdentifier = UUID().uuidString` default added to PersonEntity
    /// (plan 22) is evaluated ONCE during migration of a shipped store, so
    /// every pre-existing row received the SAME identifier — breaking
    /// ForEach identity, multi-select, merge tie-breaks, link-cache keys,
    /// and v2 import upserts.
    ///
    /// Rows sharing an identifier are repaired here: the deterministic
    /// survivor — lowest `SyncDedupe.persistentIDString`, the same rule the
    /// dedupe pass uses — KEEPS the shared identifier (so any per-device
    /// contact link keyed to it stays attached to exactly one person); every
    /// other row gets a fresh UUID. Runs on every rebuild (a cheap no-op
    /// once identifiers are unique); the caller's save persists the change.
    static func backfillSharedIdentifiers(_ people: [PersonEntity]) {
        for group in Dictionary(grouping: people, by: \.uniqueIdentifier).values
        where group.count > 1 {
            let ordered = group.sorted {
                SyncDedupe.persistentIDString($0) < SyncDedupe.persistentIDString($1)
            }
            for extra in ordered.dropFirst() {
                extra.uniqueIdentifier = UUID().uuidString
            }
        }
    }
}
