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

// MARK: - The shipped Reporter/Tumblr seed file

private func shippedSeedURL() -> URL {
    // Tests run from the package root; docs/ sits beside Sources/.
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/DispatchKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("docs/catalog/reporter-tumblr-seed.json")
}

@Test func shippedReporterTumblrSeedIsValid() throws {
    let data = try Data(contentsOf: shippedSeedURL())
    let drafts = try CatalogSeed.parse(data)
    #expect(drafts.count == 100)
    // Every draft carries the source credit (default or explicit).
    #expect(drafts.allSatisfy { $0.credit?.isEmpty == false })
    // Context tags are one of the blog's wake/day/sleep vocabulary.
    let allowedTags: Set<String> = ["wake", "day", "sleep"]
    #expect(drafts.allSatisfy { !$0.tags.isEmpty && $0.tags.allSatisfy(allowedTags.contains) })
}
