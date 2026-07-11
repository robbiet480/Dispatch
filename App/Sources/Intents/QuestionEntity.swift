import AppIntents
import DispatchKit
import Foundation
import SwiftData

/// A `Question` as an `AppEntity` so Shortcuts can parameterize the
/// "Log Answer" and "Last Answer" actions with a picker of the user's
/// questions (plan 49). Read from the SHARED App Group store READ-ONLY — the
/// `PromptGroupEntity` precedent — since the system may query it from a
/// background-launched process while the foreground app holds the store.
///
/// Only ENABLED questions on the regular report surface are offered: those are
/// the ones `IntentAnswerFiler` will actually file against, so Shortcuts can't
/// bind a value to a question that would be silently rejected.
struct QuestionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Question"
    static let defaultQuery = QuestionEntityQuery()

    var id: String
    var prompt: String
    /// Question type raw (see `QuestionType`) — carried so an intent can show
    /// a type-appropriate value hint without a second store read.
    var typeRaw: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(prompt)")
    }
}

struct QuestionEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [QuestionEntity] {
        Self.enabledRegularQuestions().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [QuestionEntity] {
        Self.enabledRegularQuestions()
    }

    /// Enabled, regular-kind questions in sort order — the exact set
    /// `IntentAnswerFiler.eligibleQuestion` accepts. Missing store → no
    /// options rather than an error in the Shortcuts UI.
    static func enabledRegularQuestions() -> [QuestionEntity] {
        guard let context = IntentStore.readOnlyContext() else { return [] }
        let descriptor = FetchDescriptor<Question>(sortBy: [SortDescriptor(\.sortOrder)])
        guard let questions = try? context.fetch(descriptor) else { return [] }
        return questions
            .filter { $0.isEnabled && $0.reportKinds.contains(.regular) }
            .map { question in
                let trimmed = question.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                return QuestionEntity(
                    id: question.uniqueIdentifier,
                    prompt: trimmed.isEmpty ? "Untitled question" : trimmed,
                    typeRaw: question.typeRaw
                )
            }
    }
}
