import Foundation
import Testing
@testable import DispatchKit

@Test func remoteGroupEditRequiresReplan() {
    // Issue #57's core requirement: a PromptGroup edited on another device
    // (the Mac) must make iOS replan.
    let impact = RemoteChangeImpact.classify(changedEntityNames: ["PromptGroup"])
    #expect(impact.shouldReplanNotifications)
    #expect(!impact.shouldReconcileReports)
}

@Test func remoteQuestionEditRequiresReplan() {
    let impact = RemoteChangeImpact.classify(changedEntityNames: ["Question"])
    #expect(impact.shouldReplanNotifications)
}

@Test func remoteReportArrivalReplansAndReconciles() {
    let impact = RemoteChangeImpact.classify(changedEntityNames: ["Report"])
    #expect(impact.shouldReplanNotifications)
    #expect(impact.shouldReconcileReports)
    #expect(impact.shouldRebuildVocabulary)
}

@Test func vocabularyOnlyChangeDoesNotReplan() {
    // A downstream vocabulary write (our own rebuild echoing back) must not
    // trigger a replan or reconciliation.
    let impact = RemoteChangeImpact.classify(changedEntityNames: ["Vocabulary"])
    #expect(!impact.shouldReplanNotifications)
    #expect(!impact.shouldReconcileReports)
    #expect(!impact.shouldRebuildVocabulary)
}

@Test func emptySetIsTheDoEverythingSentinel() {
    // Unknown change set (history unavailable) => the safe always-replan floor.
    #expect(RemoteChangeImpact.classify(changedEntityNames: []) == .all)
}

@Test func unknownEntityIsTreatedConservatively() {
    let impact = RemoteChangeImpact.classify(changedEntityNames: ["FutureModel"])
    #expect(impact.shouldReplanNotifications)
    #expect(impact.shouldRebuildVocabulary)
}

@Test func responseChangeRebuildsVocabularyWithoutReplan() {
    let impact = RemoteChangeImpact.classify(changedEntityNames: ["Response"])
    #expect(!impact.shouldReplanNotifications)
    #expect(impact.shouldRebuildVocabulary)
    #expect(!impact.shouldReconcileReports)
}

@Test func entityNamesMatchModelClassNames() {
    // Guards the constant spellings the observer relies on against a model
    // rename.
    #expect(RemoteChangeImpact.EntityName.question == "\(Question.self)")
    #expect(RemoteChangeImpact.EntityName.promptGroup == "\(PromptGroup.self)")
    #expect(RemoteChangeImpact.EntityName.report == "\(Report.self)")
    #expect(RemoteChangeImpact.EntityName.response == "\(Response.self)")
}
