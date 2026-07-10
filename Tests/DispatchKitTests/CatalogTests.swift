import Foundation
import Testing
@testable import DispatchKit

// MARK: - Choices JSON

@Test func choicesJSONRoundTrips() {
    let choices = ["Great", "Okay", "Terrible", "emoji 🙂", "quote \" comma,"]
    let json = CatalogChoicesJSON.encode(choices)
    #expect(CatalogChoicesJSON.decode(json) == choices)
}

@Test func choicesJSONEmptyAndGarbage() {
    #expect(CatalogChoicesJSON.encode([]) == "[]")
    #expect(CatalogChoicesJSON.decode("[]") == [])
    #expect(CatalogChoicesJSON.decode("not json") == [])
    #expect(CatalogChoicesJSON.decode("{\"a\":1}") == [])
}

// MARK: - Field mapping round trips (kit stays CloudKit-import-free)

@Test func catalogQuestionFieldsRoundTrip() throws {
    let approvedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let original = CatalogQuestion(
        recordName: "cat-1", prompt: "How happy are you?", typeRaw: QuestionType.multipleChoice.rawValue,
        choices: ["Very", "Somewhat", "Not at all"], credit: "Robbie", approvedAt: approvedAt,
        tags: ["mood", "daily"]
    )
    let restored = try #require(CatalogQuestion(recordName: "cat-1", fields: original.fields))
    #expect(restored == original)
    #expect(restored.type == .multipleChoice)
}

@Test func catalogQuestionOmitsEmptyOptionals() {
    let question = CatalogQuestion(
        recordName: "cat-2", prompt: "What are you doing?", typeRaw: QuestionType.tokens.rawValue,
        choices: [], credit: nil, approvedAt: .now, tags: []
    )
    #expect(question.fields["credit"] == nil)
    #expect(question.fields["tags"] == nil)
    let restored = CatalogQuestion(recordName: "cat-2", fields: question.fields)
    #expect(restored?.credit == nil)
    #expect(restored?.tags == [])
}

@Test func catalogQuestionRejectsMissingRequiredFields() {
    #expect(CatalogQuestion(recordName: "x", fields: [:]) == nil)
    #expect(CatalogQuestion(recordName: "x", fields: ["prompt": .string("p")]) == nil)
    #expect(CatalogQuestion(
        recordName: "x", fields: ["prompt": .string("p"), "typeRaw": .int(0)]
    ) == nil)
}

@Test func submittedQuestionFieldsRoundTrip() throws {
    let submittedAt = Date(timeIntervalSince1970: 1_699_999_000)
    let original = SubmittedQuestion(
        recordName: "sub-1", prompt: "Who are you with?", typeRaw: QuestionType.people.rawValue,
        choices: [], creditName: "Angela", submittedAt: submittedAt
    )
    let restored = try #require(SubmittedQuestion(recordName: "sub-1", fields: original.fields))
    #expect(restored == original)
}

@Test func submissionApprovalCopiesIntoCatalogWithFreshIdentity() {
    let submission = SubmittedQuestion(
        recordName: "sub-9", prompt: "Coffee today?", typeRaw: QuestionType.yesNo.rawValue,
        choices: [], creditName: "Robbie", submittedAt: .now
    )
    let approvedAt = Date()
    let catalog = submission.approved(recordName: "cat-9", approvedAt: approvedAt, tags: ["habits"])
    #expect(catalog.recordName == "cat-9")
    #expect(catalog.recordName != submission.recordName)
    #expect(catalog.prompt == submission.prompt)
    #expect(catalog.typeRaw == submission.typeRaw)
    #expect(catalog.credit == "Robbie")
    #expect(catalog.approvedAt == approvedAt)
    #expect(catalog.tags == ["habits"])
}

@Test func questionFlagFieldsRoundTrip() throws {
    let flaggedAt = Date(timeIntervalSince1970: 1_701_234_567)
    let original = QuestionFlag(
        recordName: "flag-1", catalogRecordName: "cat-1", reason: "Spam", flaggedAt: flaggedAt
    )
    let restored = try #require(QuestionFlag(recordName: "flag-1", fields: original.fields))
    #expect(restored == original)
}

// MARK: - Validation (structural only)

@Test func validationAcceptsAllSevenTypesWithSaneShapes() {
    for type in QuestionType.allCases {
        let choices = type == .multipleChoice ? ["A", "B"] : []
        let errors = CatalogValidation.validate(
            prompt: "A perfectly fine prompt", typeRaw: type.rawValue, choices: choices
        )
        #expect(errors.isEmpty, "expected no errors for \(type)")
    }
}

@Test func validationRejectsEmptyAndOverlongPrompts() {
    #expect(CatalogValidation.validate(prompt: "", typeRaw: 0, choices: [])
        .contains(.emptyPrompt))
    #expect(CatalogValidation.validate(prompt: "   \n ", typeRaw: 0, choices: [])
        .contains(.emptyPrompt))
    let long = String(repeating: "x", count: CatalogValidation.promptMaxLength + 1)
    #expect(CatalogValidation.validate(prompt: long, typeRaw: 0, choices: [])
        .contains(.promptTooLong(limit: CatalogValidation.promptMaxLength)))
    let exact = String(repeating: "x", count: CatalogValidation.promptMaxLength)
    #expect(CatalogValidation.validate(prompt: exact, typeRaw: 0, choices: []).isEmpty)
}

@Test func validationRejectsUnknownTypeRaw() {
    #expect(CatalogValidation.validate(prompt: "p", typeRaw: 99, choices: [])
        .contains(.unknownQuestionType(raw: 99)))
    #expect(CatalogValidation.validate(prompt: "p", typeRaw: -1, choices: [])
        .contains(.unknownQuestionType(raw: -1)))
}

@Test func validationEnforcesMultipleChoiceShape() {
    let type = QuestionType.multipleChoice.rawValue
    #expect(CatalogValidation.validate(prompt: "p", typeRaw: type, choices: ["only"])
        .contains(.tooFewChoices(minimum: CatalogValidation.choicesMinimumCount)))
    let tooMany = (0...CatalogValidation.choicesMaxCount).map(String.init)
    #expect(CatalogValidation.validate(prompt: "p", typeRaw: type, choices: tooMany)
        .contains(.tooManyChoices(limit: CatalogValidation.choicesMaxCount)))
    #expect(CatalogValidation.validate(prompt: "p", typeRaw: type, choices: ["A", "  "])
        .contains(.emptyChoice))
    let longChoice = String(repeating: "y", count: CatalogValidation.choiceMaxLength + 1)
    #expect(CatalogValidation.validate(prompt: "p", typeRaw: type, choices: ["A", longChoice])
        .contains(.choiceTooLong(limit: CatalogValidation.choiceMaxLength)))
    #expect(CatalogValidation.validate(prompt: "p", typeRaw: type, choices: ["A", "a "])
        .contains(.duplicateChoice("a")))
}

@Test func validationRejectsChoicesOnNonChoiceTypes() {
    let errors = CatalogValidation.validate(
        prompt: "p", typeRaw: QuestionType.yesNo.rawValue, choices: ["stray"]
    )
    #expect(errors.contains(.choicesNotAllowed))
    // Whitespace-only stray choices are harmless.
    #expect(CatalogValidation.validate(
        prompt: "p", typeRaw: QuestionType.yesNo.rawValue, choices: ["  "]
    ).isEmpty)
}

@Test func validationLimitsCreditName() {
    let long = String(repeating: "n", count: CatalogValidation.creditNameMaxLength + 1)
    #expect(CatalogValidation.validate(prompt: "p", typeRaw: 0, choices: [], creditName: long)
        .contains(.creditNameTooLong(limit: CatalogValidation.creditNameMaxLength)))
    #expect(CatalogValidation.validate(prompt: "p", typeRaw: 0, choices: [], creditName: "Robbie").isEmpty)
    #expect(CatalogValidation.validate(prompt: "p", typeRaw: 0, choices: [], creditName: nil).isEmpty)
}

@Test func validationLimitsFlagReason() {
    let long = String(repeating: "r", count: CatalogValidation.flagReasonMaxLength + 1)
    #expect(CatalogValidation.validateFlagReason(long)
        == [.flagReasonTooLong(limit: CatalogValidation.flagReasonMaxLength)])
    // Trimmed before the length check; at-limit and empty reasons pass.
    let padded = "  " + String(repeating: "r", count: CatalogValidation.flagReasonMaxLength) + "  "
    #expect(CatalogValidation.validateFlagReason(padded).isEmpty)
    #expect(CatalogValidation.validateFlagReason("Spam").isEmpty)
    #expect(CatalogValidation.validateFlagReason("").isEmpty)
}

@Test func validationCollectsMultipleErrors() {
    let errors = CatalogValidation.validate(
        prompt: "", typeRaw: QuestionType.multipleChoice.rawValue, choices: ["only"]
    )
    #expect(errors.contains(.emptyPrompt))
    #expect(errors.contains(.tooFewChoices(minimum: CatalogValidation.choicesMinimumCount)))
}

@Test func normalizationTrimsAndCollapsesEmptyCredit() {
    let result = CatalogValidation.normalized(
        prompt: "  How was it?  ", choices: [" A ", "", "B"], creditName: "   "
    )
    #expect(result.prompt == "How was it?")
    #expect(result.choices == ["A", "B"])
    #expect(result.creditName == nil)
    let credited = CatalogValidation.normalized(prompt: "p", choices: [], creditName: " Robbie ")
    #expect(credited.creditName == "Robbie")
}
