import Foundation
import Testing
@testable import DispatchKit

private func sampleDefinitions() -> [QuestionDefinition] {
    [
        QuestionDefinition(
            prompt: "What did you eat?", typeRaw: QuestionType.tokens.rawValue,
            choices: [], reportKindsRaw: ["regular"], isEnabled: true, sortOrder: 0,
            placeholder: "food, drink…"),
        QuestionDefinition(
            prompt: "How is your energy, really?", typeRaw: QuestionType.multipleChoice.rawValue,
            choices: ["High", "Medium", "Low"], reportKindsRaw: ["wake", "regular"],
            isEnabled: false, sortOrder: 1, allowsMultipleSelection: false),
        QuestionDefinition(
            prompt: "How stressed are you?", typeRaw: QuestionType.number.rawValue,
            choices: [], reportKindsRaw: ["sleep"], isEnabled: true, sortOrder: 2,
            placeholder: "1 to 5", inputStyleRaw: "scale", defaultAnswer: "3",
            inputMin: 1, inputMax: 5),
        QuestionDefinition(
            prompt: "Notes, with a \"quote\", a comma, and\na newline.",
            typeRaw: QuestionType.note.rawValue, choices: [], reportKindsRaw: ["regular"],
            isEnabled: true, sortOrder: 3),
    ]
}

@Test func jsonRoundTripsExactly() throws {
    let originals = sampleDefinitions()
    let data = try QuestionPortability.encodeJSON(originals)
    let decoded = try QuestionPortability.decodeJSON(data)
    #expect(decoded == originals)
}

@Test func csvRoundTripsExactlyIncludingTrickyText() throws {
    let originals = sampleDefinitions()
    let csv = QuestionPortability.encodeCSV(originals)
    let decoded = try QuestionPortability.decodeCSV(csv)
    #expect(decoded == originals)
}

@Test func csvDuplicateHeaderColumnDoesNotCrash() throws {
    // A malformed header with a duplicate column name must not trap the
    // decoder (user-provided input) — first occurrence wins.
    let csv = """
    prompt,type,prompt
    Did you sleep well?,yesNo,ignored
    """
    let decoded = try QuestionPortability.decodeCSV(csv)
    #expect(decoded.count == 1)
    #expect(decoded[0].prompt == "Did you sleep well?")
    #expect(decoded[0].type == .yesNo)
}

@Test func csvHasDocumentedHeaderRow() {
    let csv = QuestionPortability.encodeCSV(sampleDefinitions())
    let firstLine = csv.split(separator: "\n", maxSplits: 1).first.map(String.init)
    #expect(firstLine == "prompt,type,choices,reportKinds,enabled,sortOrder,placeholder,inputStyle,defaultAnswer,inputMin,inputMax,inputStep,visualization,stateOfMindKind,allowsMultipleSelection")
}

@Test func catalogSeedShapedJSONImportsWithDefaults() throws {
    // A curated catalog seed file (its shape) imports here; the personal
    // fields default (enabled=true, kinds=[regular]) and catalog-only keys
    // (credit/tags) are ignored.
    let seed = """
    {
      "source": "curated",
      "defaultCredit": "Dispatch",
      "questions": [
        {"prompt": "Did you drink water today?", "type": "yesNo", "credit": "Someone", "tags": ["health"]}
      ]
    }
    """
    let decoded = try QuestionPortability.decodeJSON(Data(seed.utf8))
    #expect(decoded.count == 1)
    #expect(decoded[0].prompt == "Did you drink water today?")
    #expect(decoded[0].type == .yesNo)
    #expect(decoded[0].isEnabled == true)
    #expect(decoded[0].reportKindsRaw == ["regular"])
}

@Test func unknownJSONTypeThrows() {
    let bad = #"{"questions":[{"prompt":"x","type":"telepathy"}]}"#
    #expect(throws: QuestionPortabilityError.self) {
        try QuestionPortability.decodeJSON(Data(bad.utf8))
    }
}

@Test func questionModelBridgeRoundTrips() {
    let def = sampleDefinitions()[2] // the fully-configured number question
    let question = def.makeQuestion(sortOrder: 2)
    let back = QuestionDefinition(question)
    #expect(back == def)
}

@Test func importPlanClassifiesAddsSkipsErrors() {
    let incoming: [QuestionDefinition] = [
        QuestionDefinition(prompt: "Brand new question?", typeRaw: QuestionType.yesNo.rawValue),
        QuestionDefinition(prompt: "Already Have This!", typeRaw: QuestionType.yesNo.rawValue),
        QuestionDefinition(prompt: "brand new question", typeRaw: QuestionType.yesNo.rawValue), // dup within import (normalized)
        QuestionDefinition(prompt: "", typeRaw: QuestionType.yesNo.rawValue), // invalid: empty prompt
        QuestionDefinition(prompt: "Pick one", typeRaw: QuestionType.multipleChoice.rawValue,
                           choices: ["only-one"]), // invalid: too few choices
    ]
    let plan = QuestionImportPlan.make(
        incoming: incoming, existingPrompts: ["already have this"])
    #expect(plan.addCount == 1)
    #expect(plan.adds.first?.prompt == "Brand new question?")
    #expect(plan.skipCount == 2)
    #expect(plan.skips.contains { $0.reason == .duplicateOfExisting })
    #expect(plan.skips.contains { $0.reason == .duplicateWithinImport })
    #expect(plan.errorCount == 2)
}

@Test func cleanInstallRoundTripReproducesQuestionList() throws {
    // Export a question list, then import (JSON) into a "clean install"
    // (no existing questions) and confirm the definitions reproduce exactly.
    let questions = sampleDefinitions().enumerated().map { $0.element.makeQuestion(sortOrder: $0.offset) }
    let exported = questions.map(QuestionDefinition.init)
    let data = try QuestionPortability.encodeJSON(exported)
    let reimported = try QuestionPortability.decodeJSON(data)
    let plan = QuestionImportPlan.make(incoming: reimported, existingPrompts: [])
    #expect(plan.errorCount == 0)
    #expect(plan.skipCount == 0)
    let rebuilt = plan.adds.enumerated().map { QuestionDefinition($0.element.makeQuestion(sortOrder: $0.offset)) }
    #expect(rebuilt == exported)
}
