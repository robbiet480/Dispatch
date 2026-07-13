import Foundation
import SwiftData

public enum VocabularyBuilder {
    /// Rebuilds token/person vocabularies from all stored responses.
    /// People-type questions feed PersonEntity; token-type feed TokenEntity.
    ///
    /// Idempotent: a rebuild whose inputs are unchanged mutates nothing and
    /// returns `false` WITHOUT saving. This is load-bearing for sync — the
    /// pipeline runs on every `NSPersistentStoreRemoteChange` (which fires for
    /// this process's OWN saves too), so a rebuild that saved unconditionally
    /// would post a change, re-trigger `RemoteChangeObserver`, and loop every
    /// 2s forever — churning every vocabulary CKRecord and thrashing CloudKit
    /// export (Mac never receives a stable snapshot). Rows are matched and
    /// updated in place; only genuine deltas dirty the context.
    ///
    /// - Returns: whether the store was actually changed (and saved).
    @discardableResult
    public static func rebuild(in context: ModelContext) throws -> Bool {
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

        // Delta upsert (was: delete-all + re-insert, which recreated every
        // TokenEntity with a fresh identity on every pass — see the loop note
        // in the doc comment). Match existing rows by text, collapsing any
        // pre-dedupe duplicates onto a deterministic survivor; update counts
        // in place only when they actually differ; insert the genuinely new;
        // delete the rows no response feeds anymore.
        // Tracks whether THIS rebuild mutated the store. Gating the save and
        // the return on this (not `context.hasChanges`, which is context-wide)
        // keeps rebuild self-contained: a caller that passes a context with its
        // own pending edits can't make a no-op rebuild save that unrelated work
        // or report a false positive.
        var changed = false

        var tokenByText: [String: TokenEntity] = [:]
        for token in try context.fetch(FetchDescriptor<TokenEntity>()) {
            if let kept = tokenByText[token.text] {
                if SyncDedupe.persistentIDString(token) < SyncDedupe.persistentIDString(kept) {
                    context.delete(kept)
                    tokenByText[token.text] = token
                } else {
                    context.delete(token)
                }
                changed = true
            } else {
                tokenByText[token.text] = token
            }
        }
        for (text, tally) in tokenTally {
            if let token = tokenByText.removeValue(forKey: text) {
                if token.usageCount != tally.uses { token.usageCount = tally.uses; changed = true }
                if token.questionCount != tally.prompts.count { token.questionCount = tally.prompts.count; changed = true }
            } else {
                let entity = TokenEntity()
                entity.text = text
                entity.usageCount = tally.uses
                entity.questionCount = tally.prompts.count
                context.insert(entity)
                changed = true
            }
        }
        for stale in tokenByText.values { context.delete(stale); changed = true }

        // People are the person REGISTRY (plan 22): registry fields
        // (uniqueIdentifier, alternateNames) must survive a rebuild, so
        // instead of delete-all-recreate we match existing entities by text
        // OR alternate names and update counts in place. Only entities that
        // match no current usage AND carry no alternate names are deleted —
        // registry entries with aliases survive even at zero usage.
        let fetchedPeople = try context.fetch(FetchDescriptor<PersonEntity>())
        if backfillSharedIdentifiers(fetchedPeople) { changed = true }
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
                if person.usageCount != tally.uses { person.usageCount = tally.uses; changed = true }
                if person.questionCount != tally.prompts.count { person.questionCount = tally.prompts.count; changed = true }
            } else if person.alternateNames.isEmpty {
                context.delete(person)
                changed = true
            } else {
                if person.usageCount != 0 { person.usageCount = 0; changed = true }
                if person.questionCount != 0 { person.questionCount = 0; changed = true }
            }
        }
        for (text, tally) in unmatched {
            let entity = PersonEntity()
            entity.text = text
            entity.usageCount = tally.uses
            entity.questionCount = tally.prompts.count
            context.insert(entity)
            changed = true
        }

        // Save ONLY when this rebuild actually mutated the store. An unchanged
        // rebuild touches nothing, so it posts no NSPersistentStoreRemoteChange
        // — the sync-loop terminator.
        if changed { try context.save() }
        return changed
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
    ///
    /// - Returns: whether any identifier was reassigned, so `rebuild` can fold
    ///   this into its own change tracking (a no-op backfill must not make an
    ///   otherwise-unchanged rebuild save).
    @discardableResult
    static func backfillSharedIdentifiers(_ people: [PersonEntity]) -> Bool {
        var changed = false
        for group in Dictionary(grouping: people, by: \.uniqueIdentifier).values
        where group.count > 1 {
            let ordered = group.sorted {
                SyncDedupe.persistentIDString($0) < SyncDedupe.persistentIDString($1)
            }
            for extra in ordered.dropFirst() {
                extra.uniqueIdentifier = UUID().uuidString
                changed = true
            }
        }
        return changed
    }
}
