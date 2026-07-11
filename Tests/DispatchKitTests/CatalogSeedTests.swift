import Foundation
import Testing
@testable import DispatchKit

private func seedData(_ json: String) -> Data { Data(json.utf8) }

// MARK: - Parsing

@Test func seedParsesEveryTypeName() throws {
    let json = """
    {"questions": [
      {"prompt": "Tokens?", "type": "tokens"},
      {"prompt": "Choice?", "type": "multipleChoice", "choices": ["A", "B"]},
      {"prompt": "Yes or no?", "type": "yesNo"},
      {"prompt": "Where?", "type": "location"},
      {"prompt": "Who?", "type": "people"},
      {"prompt": "How many?", "type": "number"},
      {"prompt": "Thoughts?", "type": "note"}
    ]}
    """
    let drafts = try CatalogSeed.parse(seedData(json))
    #expect(drafts.map(\.typeRaw) == [
        QuestionType.tokens, .multipleChoice, .yesNo, .location, .people, .number, .note,
    ].map(\.rawValue))
    #expect(drafts[1].choices == ["A", "B"])
}

@Test func seedAppliesDefaultCreditAndPerEntryOverride() throws {
    let json = """
    {"defaultCredit": "Community", "questions": [
      {"prompt": "One?", "type": "yesNo"},
      {"prompt": "Two?", "type": "yesNo", "credit": "Alice"}
    ]}
    """
    let drafts = try CatalogSeed.parse(seedData(json))
    #expect(drafts[0].credit == "Community")
    #expect(drafts[1].credit == "Alice")
}

@Test func seedNormalizesWhitespaceAndTags() throws {
    let json = """
    {"questions": [
      {"prompt": "  Padded?  ", "type": "multipleChoice",
       "choices": [" A ", "B"], "tags": [" wake ", ""]}
    ]}
    """
    let drafts = try CatalogSeed.parse(seedData(json))
    #expect(drafts[0].prompt == "Padded?")
    #expect(drafts[0].choices == ["A", "B"])
    #expect(drafts[0].tags == ["wake"])
}

// MARK: - Input configuration (plan 41)

@Test func seedCarriesInputConfig() throws {
    let json = """
    {"questions": [
      {"prompt": "How many cups?", "type": "number",
       "inputStyle": "slider", "inputMin": 0, "inputMax": 100,
       "defaultAnswer": "50", "placeholder": "0–100"}
    ]}
    """
    let drafts = try CatalogSeed.parse(seedData(json))
    #expect(drafts[0].inputStyle == "slider")
    #expect(drafts[0].defaultAnswer == "50")
    #expect(drafts[0].placeholder == "0–100")
    #expect(drafts[0].inputMin == 0)
    #expect(drafts[0].inputMax == 100)
    #expect(drafts[0].inputStep == nil)

    let question = drafts[0].catalogQuestion(recordName: "rec-41", approvedAt: .now)
    #expect(question.inputStyle == "slider")
    #expect(question.defaultAnswer == "50")
    #expect(question.placeholder == "0–100")
    #expect(question.inputMin == 0)
    #expect(question.inputMax == 100)
    #expect(question.inputStep == nil)
}

@Test func seedWithoutInputConfigStillParses() throws {
    // Back-compat: older seed files never mention the plan-41 keys.
    let json = """
    {"questions": [{"prompt": "How many?", "type": "number"}]}
    """
    let drafts = try CatalogSeed.parse(seedData(json))
    #expect(drafts[0].inputStyle == nil)
    #expect(drafts[0].defaultAnswer == nil)
    #expect(drafts[0].placeholder == nil)
    #expect(drafts[0].inputMin == nil)
    #expect(drafts[0].inputMax == nil)
    #expect(drafts[0].inputStep == nil)
}

@Test func seedRejectsInputConfigOnWrongTypes() {
    let json = """
    {"questions": [
      {"prompt": "Yes with a style?", "type": "yesNo", "inputStyle": "slider"},
      {"prompt": "Note with a default?", "type": "note", "defaultAnswer": "3"}
    ]}
    """
    do {
        _ = try CatalogSeed.parse(seedData(json))
        Issue.record("expected CatalogSeedError")
    } catch let CatalogSeedError.problems(problems) {
        #expect(problems.count == 2)
        #expect(problems[0].contains("Input style"))
        #expect(problems[1].contains("Default answers"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// MARK: - Problem collection

@Test func seedCollectsAllProblemsAcrossEntries() {
    let json = """
    {"questions": [
      {"prompt": "Bad type?", "type": "essay"},
      {"prompt": "One choice?", "type": "multipleChoice", "choices": ["Only"]},
      {"prompt": "Choices on yes/no?", "type": "yesNo", "choices": ["A", "B"]},
      {"prompt": "Fine?", "type": "yesNo"},
      {"prompt": "fine?", "type": "note"}
    ]}
    """
    do {
        _ = try CatalogSeed.parse(seedData(json))
        Issue.record("expected CatalogSeedError")
    } catch let CatalogSeedError.problems(problems) {
        #expect(problems.count == 4)
        #expect(problems[0].contains("unknown type"))
        #expect(problems[1].contains("at least 2"))
        #expect(problems[2].contains("Only multiple-choice"))
        #expect(problems[3].contains("duplicate prompt"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func seedRejectsMalformedJSON() {
    #expect(throws: CatalogSeedError.self) {
        _ = try CatalogSeed.parse(seedData("not json"))
    }
    #expect(throws: CatalogSeedError.self) {
        _ = try CatalogSeed.parse(seedData("{\"questions\": [{\"prompt\": \"no type\"}]}"))
    }
}

// MARK: - Draft → record mapping

@Test func seedDraftBuildsCatalogQuestion() {
    let draft = CatalogSeedDraft(
        prompt: "How are you?", typeRaw: QuestionType.multipleChoice.rawValue,
        choices: ["Happy", "Sad"], credit: "Community", tags: ["day"]
    )
    let approvedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let question = draft.catalogQuestion(recordName: "rec-1", approvedAt: approvedAt)
    #expect(question.recordName == "rec-1")
    #expect(question.prompt == "How are you?")
    #expect(question.type == .multipleChoice)
    #expect(question.choices == ["Happy", "Sad"])
    #expect(question.credit == "Community")
    #expect(question.approvedAt == approvedAt)
    #expect(question.tags == ["day"])
}

// MARK: - The shipped seed files

private func shippedSeedURL(_ filename: String) -> URL {
    // Tests run from the package root; docs/ sits beside Sources/.
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/DispatchKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("docs/catalog/\(filename)")
}

@Test(arguments: [("reporter-tumblr-seed.json", 100), ("dispatch-starter-seed.json", 44)])
func shippedSeedIsValid(filename: String, count: Int) throws {
    let data = try Data(contentsOf: shippedSeedURL(filename))
    let drafts = try CatalogSeed.parse(data)
    #expect(drafts.count == count)
    // Every draft carries a credit (default or explicit).
    #expect(drafts.allSatisfy { $0.credit?.isEmpty == false })
    // Context tags stick to the wake/day/sleep vocabulary.
    let allowedTags: Set<String> = ["wake", "day", "sleep"]
    #expect(drafts.allSatisfy { !$0.tags.isEmpty && $0.tags.allSatisfy(allowedTags.contains) })
}

@Test func shippedSeedFilesDoNotOverlap() throws {
    let tumblr = try CatalogSeed.parse(Data(contentsOf: shippedSeedURL("reporter-tumblr-seed.json")))
    let starter = try CatalogSeed.parse(Data(contentsOf: shippedSeedURL("dispatch-starter-seed.json")))
    let tumblrPrompts = Set(tumblr.map { $0.prompt.lowercased() })
    let overlap = starter.filter { tumblrPrompts.contains($0.prompt.lowercased()) }
    #expect(overlap.isEmpty, "starter prompts duplicated from the Tumblr set: \(overlap.map(\.prompt))")
}
