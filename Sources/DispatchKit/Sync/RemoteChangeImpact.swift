import Foundation

/// What a remote-change batch (CloudKit mirroring landing another device's
/// edits) requires the receiving device to do — plan 47, the ONE tested
/// definition of "a remote edit that must replan".
///
/// This exists because of issue #57's trickiest correctness requirement:
/// a prompt group or question edited on the MAC lands on the iPhone via
/// CloudKit mirroring, and iOS must REPLAN notifications so the edit takes
/// effect without waiting for the next app-open replan. `RemoteChangeObserver`
/// (iOS) computes the changed model-entity names from persistent history and
/// consults `classify(changedEntityNames:)`.
///
/// Safety contract: an EMPTY set means "the changed entities are unknown"
/// (history unavailable / not parsed), and the classifier returns the
/// do-everything sentinel — the coarse always-replan that shipped before this
/// classifier existed. An UNKNOWN entity name is likewise treated
/// conservatively (replan). So the classifier can only ever make behavior
/// MORE precise than the always-replan floor, never drop a needed replan.
public struct RemoteChangeImpact: Equatable, Sendable {
    /// Notifications must be re-planned (`NotificationScheduler.replanNow`).
    public var shouldReplanNotifications: Bool
    /// Recently-filed synced reports must feed nag reconciliation before the
    /// replan (plan 19) — only when `Report` rows changed.
    public var shouldReconcileReports: Bool
    /// The token/person vocabulary must be rebuilt — when answer-bearing rows
    /// (`Report`/`Response`) changed.
    public var shouldRebuildVocabulary: Bool

    public init(shouldReplanNotifications: Bool,
                shouldReconcileReports: Bool,
                shouldRebuildVocabulary: Bool) {
        self.shouldReplanNotifications = shouldReplanNotifications
        self.shouldReconcileReports = shouldReconcileReports
        self.shouldRebuildVocabulary = shouldRebuildVocabulary
    }

    /// The do-everything sentinel — returned for an empty (unknown) change set.
    public static let all = RemoteChangeImpact(
        shouldReplanNotifications: true,
        shouldReconcileReports: true,
        shouldRebuildVocabulary: true
    )

    /// SwiftData persists each `@Model` under its class name; these are the
    /// entity names persistent-history changes report. Kept as constants so
    /// the observer and the classifier agree on one spelling.
    public enum EntityName {
        public static let question = "Question"
        public static let promptGroup = "PromptGroup"
        public static let report = "Report"
        public static let response = "Response"
        public static let tokenEntity = "TokenEntity"
        public static let personEntity = "PersonEntity"
        public static let vocabulary = "Vocabulary"

        /// Entities that affect the notification schedule when edited remotely:
        /// questions (prompt/kind/enable changes reshape surveys), groups
        /// (membership/schedule/enable), and reports (arrivals quiet nag
        /// chains, applied by the replan that follows reconciliation).
        static let replanRelevant: Set<String> = [question, promptGroup, report]
        /// Answer-bearing entities whose remote changes can shift the token/
        /// person vocabulary.
        static let vocabularyRelevant: Set<String> = [report, response, tokenEntity, personEntity]
    }

    /// Classify a remote-change batch by the model-entity names it touched.
    ///
    /// - An EMPTY set is the "unknown, do everything" sentinel (`.all`).
    /// - Any UNKNOWN entity name (not one of `EntityName`'s cases) is treated
    ///   as replan-relevant AND vocabulary-relevant — conservative, so a
    ///   future model can't silently skip a replan.
    public static func classify(changedEntityNames: Set<String>) -> RemoteChangeImpact {
        guard !changedEntityNames.isEmpty else { return .all }
        let known: Set<String> = [
            EntityName.question, EntityName.promptGroup, EntityName.report,
            EntityName.response, EntityName.tokenEntity, EntityName.personEntity,
            EntityName.vocabulary,
        ]
        let hasUnknown = !changedEntityNames.isSubset(of: known)
        let reportsChanged = changedEntityNames.contains(EntityName.report)
        let replan = hasUnknown || !changedEntityNames.isDisjoint(with: EntityName.replanRelevant)
        let rebuild = hasUnknown || !changedEntityNames.isDisjoint(with: EntityName.vocabularyRelevant)
        return RemoteChangeImpact(
            shouldReplanNotifications: replan,
            shouldReconcileReports: reportsChanged,
            shouldRebuildVocabulary: rebuild
        )
    }
}
