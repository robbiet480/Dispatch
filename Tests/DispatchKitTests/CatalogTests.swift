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

// MARK: - Field values (plan 41 adds .double for the input-style bounds)

@Test func catalogFieldValueDoubleAccessor() {
    #expect(CatalogFieldValue.double(2.5).doubleValue == 2.5)
    #expect(CatalogFieldValue.double(2.5).stringValue == nil)
    #expect(CatalogFieldValue.double(2.5).intValue == nil)
    #expect(CatalogFieldValue.double(2.5).dateValue == nil)
    #expect(CatalogFieldValue.double(2.5).stringListValue == nil)
    #expect(CatalogFieldValue.string("2.5").doubleValue == nil)
    #expect(CatalogFieldValue.int(2).doubleValue == nil)
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

// MARK: - Prompt fingerprint (plan 42)

@Test func catalogQuestionFingerprintRoundTripsAndOmitsWhenNil() throws {
    let stamped = CatalogQuestion(
        recordName: "cat-fp", prompt: "Did you exercise today?", typeRaw: QuestionType.yesNo.rawValue,
        choices: [], approvedAt: Date(timeIntervalSince1970: 1_700_000_000),
        promptFingerprint: CatalogDedupe.promptFingerprint("Did you exercise today?")
    )
    #expect(stamped.fields["promptFingerprint"]?.stringValue
        == CatalogDedupe.promptFingerprint("Did you exercise today?"))
    let restored = try #require(CatalogQuestion(recordName: "cat-fp", fields: stamped.fields))
    #expect(restored == stamped)

    // Pre-plan-42 records have no fingerprint: nil-omitted, decodes nil.
    let bare = CatalogQuestion(
        recordName: "cat-old", prompt: "Old entry?", typeRaw: QuestionType.yesNo.rawValue,
        choices: [], approvedAt: .now
    )
    #expect(bare.fields["promptFingerprint"] == nil)
    #expect(CatalogQuestion(recordName: "cat-old", fields: bare.fields)?.promptFingerprint == nil)
}

@Test func approvalStampsPromptFingerprint() {
    let submission = SubmittedQuestion(
        recordName: "sub-fp", prompt: "  Did you  exercise today?!", typeRaw: QuestionType.yesNo.rawValue,
        choices: [], submittedAt: .now
    )
    let catalog = submission.approved(recordName: "cat-fp2", approvedAt: .now)
    #expect(catalog.promptFingerprint == CatalogDedupe.promptFingerprint("did you exercise today"))
}

@Test func seedDraftStampsPromptFingerprint() {
    let draft = CatalogSeedDraft(
        prompt: "How are you?", typeRaw: QuestionType.note.rawValue, choices: []
    )
    let question = draft.catalogQuestion(recordName: "cat-fp3", approvedAt: .now)
    #expect(question.promptFingerprint == CatalogDedupe.promptFingerprint("How are you?"))
}

// MARK: - Input configuration fields (plan 41)

@Test func submittedQuestionInputConfigRoundTrips() throws {
    let original = SubmittedQuestion(
        recordName: "sub-41", prompt: "How was it?", typeRaw: QuestionType.number.rawValue,
        choices: [], creditName: nil, submittedAt: Date(timeIntervalSince1970: 1_700_000_000),
        inputStyle: "scale", defaultAnswer: "3", placeholder: "1–5",
        inputMin: 1, inputMax: 5, inputStep: 1
    )
    let restored = try #require(SubmittedQuestion(recordName: "sub-41", fields: original.fields))
    #expect(restored == original)
    #expect(restored.inputStyle == "scale")
    #expect(restored.defaultAnswer == "3")
    #expect(restored.placeholder == "1–5")
    #expect(restored.inputMin == 1)
    #expect(restored.inputMax == 5)
    #expect(restored.inputStep == 1)
}

@Test func submittedQuestionOmitsNilInputConfig() throws {
    let plain = SubmittedQuestion(
        recordName: "sub-42", prompt: "Coffee?", typeRaw: QuestionType.yesNo.rawValue,
        choices: [], creditName: nil, submittedAt: .now
    )
    for key in ["inputStyle", "defaultAnswer", "placeholder", "inputMin", "inputMax", "inputStep"] {
        #expect(plain.fields[key] == nil, "nil \(key) must be omitted from the field dictionary")
    }
    let restored = try #require(SubmittedQuestion(recordName: "sub-42", fields: plain.fields))
    #expect(restored == plain)
}

@Test func catalogQuestionInputConfigRoundTrips() throws {
    let original = CatalogQuestion(
        recordName: "cat-41", prompt: "Stress level?", typeRaw: QuestionType.number.rawValue,
        choices: [], credit: "Robbie", approvedAt: Date(timeIntervalSince1970: 1_700_000_000),
        tags: ["mood"], inputStyle: "slider", defaultAnswer: "50", placeholder: "0–100",
        inputMin: 0, inputMax: 100, inputStep: 5
    )
    let restored = try #require(CatalogQuestion(recordName: "cat-41", fields: original.fields))
    #expect(restored == original)

    let plain = CatalogQuestion(
        recordName: "cat-42", prompt: "Water?", typeRaw: QuestionType.yesNo.rawValue,
        choices: [], credit: nil, approvedAt: .now, tags: []
    )
    for key in ["inputStyle", "defaultAnswer", "placeholder", "inputMin", "inputMax", "inputStep"] {
        #expect(plain.fields[key] == nil, "nil \(key) must be omitted from the field dictionary")
    }
}

@Test func approvalCarriesInputConfigOntoCatalogEntry() {
    let submission = SubmittedQuestion(
        recordName: "sub-43", prompt: "Energy?", typeRaw: QuestionType.number.rawValue,
        choices: [], creditName: "Angela", submittedAt: .now,
        inputStyle: "dial", defaultAnswer: "7", placeholder: "spin it",
        inputMin: 0, inputMax: 10, inputStep: 0.5
    )
    let catalog = submission.approved(recordName: "cat-43", approvedAt: .now, tags: [])
    #expect(catalog.inputStyle == "dial")
    #expect(catalog.defaultAnswer == "7")
    #expect(catalog.placeholder == "spin it")
    #expect(catalog.inputMin == 0)
    #expect(catalog.inputMax == 10)
    #expect(catalog.inputStep == 0.5)
}

// MARK: - Creator metadata (plan 38: moderation-side only)

@Test func creatorMetadataDefaultsNilAndNeverWritesAField() {
    let plain = SubmittedQuestion(
        recordName: "sub-50", prompt: "Sleep well?", typeRaw: QuestionType.yesNo.rawValue,
        choices: [], submittedAt: .now
    )
    #expect(plain.createdUserRecordName == nil)

    // The creator identity is CloudKit's own metadata, read at moderation
    // time — the app never stores it, so it must never appear in the field
    // dictionary that becomes the record body.
    let tagged = SubmittedQuestion(
        recordName: "sub-51", prompt: "Sleep well?", typeRaw: QuestionType.yesNo.rawValue,
        choices: [], submittedAt: .now, createdUserRecordName: "_abc123"
    )
    #expect(tagged.createdUserRecordName == "_abc123")
    #expect(tagged.fields["createdUserRecordName"] == nil)
    #expect(!tagged.fields.keys.contains { $0.lowercased().contains("created") })

    // Round-tripping through fields drops the metadata (it isn't a field).
    let restored = SubmittedQuestion(recordName: "sub-51", fields: tagged.fields)
    #expect(restored?.createdUserRecordName == nil)
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

/// Plan 28: time questions ARE allowed in community submissions (raw 7 resolves
/// structurally), carry no choices, and still reject choices like any non-choice type.
@Test func validationAllowsTimeQuestionsWithoutChoices() {
    #expect(CatalogValidation.validate(
        prompt: "What time did you last eat?", typeRaw: QuestionType.time.rawValue, choices: []
    ).isEmpty)
    #expect(CatalogValidation.validate(
        prompt: "What time did you last eat?", typeRaw: QuestionType.time.rawValue, choices: ["Morning"]
    ).contains(.choicesNotAllowed))
    #expect(CatalogValidation.validate(
        prompt: "p", typeRaw: 99, choices: []
    ).contains(.unknownQuestionType(raw: 99)))
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

// MARK: - Input configuration validation (plan 41)

@Test func validationAcceptsFullyConfiguredNumberQuestion() {
    #expect(CatalogValidation.validate(
        prompt: "Stress level?", typeRaw: QuestionType.number.rawValue, choices: [],
        inputStyle: "scale", defaultAnswer: "3", placeholder: "1–5"
    ).isEmpty)
}

@Test func validationRejectsInputStyleAndDefaultAnswerOnNonNumberTypes() {
    let yesNo = QuestionType.yesNo.rawValue
    #expect(CatalogValidation.validate(
        prompt: "p", typeRaw: yesNo, choices: [], inputStyle: "slider"
    ) == [.inputStyleNotAllowed])
    #expect(CatalogValidation.validate(
        prompt: "p", typeRaw: yesNo, choices: [], defaultAnswer: "3"
    ) == [.defaultAnswerNotAllowed])
    // Placeholder is allowed on ANY type (the editor's PLACEHOLDER section
    // is unconditional).
    #expect(CatalogValidation.validate(
        prompt: "p", typeRaw: yesNo, choices: [], placeholder: "hint"
    ).isEmpty)
    // Whitespace-only values are treated as absent.
    #expect(CatalogValidation.validate(
        prompt: "p", typeRaw: yesNo, choices: [], inputStyle: "  ", defaultAnswer: " \n"
    ).isEmpty)
}

@Test func validationToleratesUnknownInputStyleOnNumberQuestions() {
    // Leniency: an unknown raw resolves to a text field on old builds; it is
    // never a validation error on a number question.
    #expect(CatalogValidation.validate(
        prompt: "p", typeRaw: QuestionType.number.rawValue, choices: [], inputStyle: "hologram"
    ).isEmpty)
}

@Test func validationLimitsDefaultAnswerAndPlaceholderLengths() {
    let number = QuestionType.number.rawValue
    let longDefault = String(repeating: "9", count: CatalogValidation.defaultAnswerMaxLength + 1)
    #expect(CatalogValidation.validate(
        prompt: "p", typeRaw: number, choices: [], defaultAnswer: longDefault
    ) == [.defaultAnswerTooLong(limit: CatalogValidation.defaultAnswerMaxLength)])
    let longPlaceholder = String(repeating: "h", count: CatalogValidation.placeholderMaxLength + 1)
    #expect(CatalogValidation.validate(
        prompt: "p", typeRaw: number, choices: [], placeholder: longPlaceholder
    ) == [.placeholderTooLong(limit: CatalogValidation.placeholderMaxLength)])
    // Trimmed before counting: padding around an at-limit value passes.
    let paddedDefault = "  " + String(repeating: "9", count: CatalogValidation.defaultAnswerMaxLength) + "  "
    let paddedPlaceholder = " " + String(repeating: "h", count: CatalogValidation.placeholderMaxLength) + " "
    #expect(CatalogValidation.validate(
        prompt: "p", typeRaw: number, choices: [],
        defaultAnswer: paddedDefault, placeholder: paddedPlaceholder
    ).isEmpty)
}

@Test func normalizationTrimsAndCollapsesInputConfigStrings() {
    let result = CatalogValidation.normalized(
        prompt: " p ", choices: [], creditName: nil,
        inputStyle: " scale ", defaultAnswer: "  ", placeholder: " 1–5 "
    )
    #expect(result.inputStyle == "scale")
    #expect(result.defaultAnswer == nil)
    #expect(result.placeholder == "1–5")
    let empty = CatalogValidation.normalized(prompt: "p", choices: [], creditName: nil)
    #expect(empty.inputStyle == nil)
    #expect(empty.defaultAnswer == nil)
    #expect(empty.placeholder == nil)
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
