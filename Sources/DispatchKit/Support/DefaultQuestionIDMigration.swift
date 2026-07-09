import Foundation
import os
import SwiftData

private let migrationLog = Logger(subsystem: "io.robbie.Dispatch", category: "migration")

/// One-time launch migration: rewrites the legacy seeded question identifiers
/// (`default-question-<N>`) to the deterministic UUIDv5 identifiers in
/// `DefaultQuestions`, everywhere they are referenced. Must run before
/// anything reads questions, and MUST ship before CloudKit sync does.
public enum DefaultQuestionIDMigration {
    /// Defaults flag marking the migration as complete. Only set after a
    /// successful save, so a failed run retries on the next launch.
    public static let defaultsFlagKey = "migration.defaultQuestionUUIDs"

    public struct Summary: Equatable, Sendable {
        public var questions = 0
        public var responses = 0
        public var promptGroupReferences = 0
        public var hiddenVisualizationIDs = 0

        public var total: Int { questions + responses + promptGroupReferences + hiddenVisualizationIDs }
    }

    /// Idempotent: guarded by the defaults flag AND by the presence of legacy
    /// identifiers (a store with none — fresh install or already migrated —
    /// just sets the flag). All model rewrites happen in the given context
    /// with a single save. Dangling references (a `Response.questionIdentifier`
    /// or `PromptGroup.questionIDs` entry whose question no longer exists) are
    /// still rewritten via the frozen N → slug table.
    @discardableResult
    public static func runIfNeeded(context: ModelContext, defaults: UserDefaults) throws -> Summary? {
        guard !defaults.bool(forKey: defaultsFlagKey) else { return nil }

        var summary = Summary()

        for question in try context.fetch(FetchDescriptor<Question>()) {
            guard let newID = DefaultQuestions.migratedIdentifier(forLegacyID: question.uniqueIdentifier) else { continue }
            question.uniqueIdentifier = newID
            summary.questions += 1
        }

        for response in try context.fetch(FetchDescriptor<Response>()) {
            guard let oldID = response.questionIdentifier,
                  let newID = DefaultQuestions.migratedIdentifier(forLegacyID: oldID) else { continue }
            response.questionIdentifier = newID
            summary.responses += 1
        }

        for group in try context.fetch(FetchDescriptor<PromptGroup>()) {
            var rewrites = 0
            let rewritten = group.questionIDs.map { id -> String in
                guard let newID = DefaultQuestions.migratedIdentifier(forLegacyID: id) else { return id }
                rewrites += 1
                return newID
            }
            if rewrites > 0 {
                group.questionIDs = rewritten
                summary.promptGroupReferences += rewrites
            }
        }

        if context.hasChanges {
            try context.save()
        }

        // VisualizationFilterStore persists hidden question IDs as a plain
        // string array in defaults; rewrite matching entries in place. Runs
        // after the model save so a save failure leaves defaults untouched.
        if let hidden = defaults.stringArray(forKey: VisualizationFilterStore.hiddenQuestionIDsDefaultsKey) {
            var rewrites = 0
            let rewritten = hidden.map { id -> String in
                guard let newID = DefaultQuestions.migratedIdentifier(forLegacyID: id) else { return id }
                rewrites += 1
                return newID
            }
            if rewrites > 0 {
                defaults.set(rewritten, forKey: VisualizationFilterStore.hiddenQuestionIDsDefaultsKey)
                summary.hiddenVisualizationIDs = rewrites
            }
        }

        defaults.set(true, forKey: defaultsFlagKey)

        if summary.total > 0 {
            migrationLog.info("""
            migrated legacy default-question IDs — questions: \(summary.questions, privacy: .public), \
            responses: \(summary.responses, privacy: .public), \
            promptGroup refs: \(summary.promptGroupReferences, privacy: .public), \
            hidden viz IDs: \(summary.hiddenVisualizationIDs, privacy: .public)
            """)
        } else {
            migrationLog.info("no legacy default-question IDs found; marked migration complete")
        }
        return summary
    }
}
