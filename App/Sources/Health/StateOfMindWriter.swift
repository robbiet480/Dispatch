import DispatchKit
import Foundation
import HealthKit
import os
import SwiftData

private let stateOfMindLog = Logger(subsystem: "io.robbie.Dispatch", category: "stateOfMind")

/// Writes Apple Health `HKStateOfMind` samples for report answers whose
/// question opts into mood logging (`Question.stateOfMindKind`).
/// Best-effort only: every failure path (authorization denied, save
/// error, missing response) is logged and swallowed — a failed Health
/// write must never fail or roll back a report save.
@MainActor
enum StateOfMindWriter {
    private static let store = HKHealthStore()
    private static var hasRequestedAuthorization = false

    /// Writes one HKStateOfMind sample per answered response whose question
    /// has a non-nil `stateOfMindKind`, then records the resulting sample
    /// UUIDs on the report and saves the context.
    static func write(for report: Report, in questions: [Question], context: ModelContext) async {
        guard HKHealthStore.isHealthDataAvailable() else {
            stateOfMindLog.notice("health data unavailable; skipping state of mind write")
            return
        }

        let moodQuestions = questions.filter { $0.stateOfMindKind != nil }
        guard !moodQuestions.isEmpty else { return }

        if !hasRequestedAuthorization {
            let stateOfMindType = HKObjectType.stateOfMindType()
            do {
                try await store.requestAuthorization(toShare: [stateOfMindType], read: [])
                hasRequestedAuthorization = true
            } catch {
                stateOfMindLog.error("state of mind authorization failed: \(error, privacy: .public)")
                return
            }
        }

        var newSampleIDs: [String] = []

        for question in moodQuestions {
            guard let response = (report.responses ?? []).first(where: { response in
                if let questionIdentifier = response.questionIdentifier {
                    return questionIdentifier == question.uniqueIdentifier
                }
                return response.questionPrompt == question.prompt
            }) else { continue }

            guard let valence = valence(for: response, question: question) else { continue }

            let sample = HKStateOfMind(date: report.date, kind: .momentaryEmotion,
                                       valence: valence, labels: [], associations: [])
            do {
                try await store.save(sample)
                newSampleIDs.append(sample.uuid.uuidString)
            } catch {
                stateOfMindLog.error("state of mind save failed: \(error, privacy: .public)")
            }
        }

        guard !newSampleIDs.isEmpty else { return }

        report.stateOfMindSampleIDs.append(contentsOf: newSampleIDs)
        do {
            try context.save()
        } catch {
            stateOfMindLog.error("failed to save state of mind sample ids: \(error, privacy: .public)")
        }
    }

    /// Delegates to the pure `StateOfMindValence.value` mapping. Returns nil
    /// for skipped/unanswered responses.
    private static func valence(for response: Response, question: Question) -> Double? {
        StateOfMindValence.value(
            answer: response.answeredOptions?.first,
            choices: question.choices,
            type: question.type
        )
    }
}
