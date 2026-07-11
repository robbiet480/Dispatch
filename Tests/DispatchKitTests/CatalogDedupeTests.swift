import Foundation
import Testing
@testable import DispatchKit

// MARK: - Normalization

@Test func dedupeNormalizationFoldsCaseWhitespaceAndTrailingPunctuation() {
    #expect(CatalogDedupe.normalizedPrompt("  Did you  exercise today?!") == "did you exercise today")
    #expect(CatalogDedupe.normalizedPrompt("Did you exercise\ntoday?") == "did you exercise today")
    #expect(CatalogDedupe.normalizedPrompt("Did you exercise today…") == "did you exercise today")
    #expect(CatalogDedupe.normalizedPrompt("Really‽") == "really")
}

@Test func dedupeNormalizationKeepsInternalPunctuation() {
    #expect(CatalogDedupe.normalizedPrompt("Coffee? Tea?") == "coffee? tea")
    #expect(CatalogDedupe.normalizedPrompt("1, 2, or 3?") == "1, 2, or 3")
}

@Test func dedupeNormalizationFoldsCurlyQuotes() {
    #expect(CatalogDedupe.normalizedPrompt("Who’d you meet?") == "who'd you meet")
    #expect(CatalogDedupe.normalizedPrompt("Read “the” book?") == "read \"the\" book")
    #expect(CatalogDedupe.isDuplicate("Who’d you meet?", "who'd you meet"))
}

@Test func dedupeNormalizationAppliesNFC() {
    let composed = "caf\u{E9}?"          // café? (precomposed é)
    let decomposed = "cafe\u{301}?"      // café? (e + combining acute)
    #expect(CatalogDedupe.normalizedPrompt(composed) == CatalogDedupe.normalizedPrompt(decomposed))
}

@Test func dedupeNormalizationDoesNotFoldDiacritics() {
    // Conservative v1: café and cafe are DIFFERENT prompts.
    #expect(CatalogDedupe.normalizedPrompt("café") != CatalogDedupe.normalizedPrompt("cafe"))
}

@Test func dedupeNormalizationCollapsesEmptyInput() {
    #expect(CatalogDedupe.normalizedPrompt("") == "")
    #expect(CatalogDedupe.normalizedPrompt("   \n  ") == "")
    #expect(CatalogDedupe.normalizedPrompt("?!…") == "")
}

// MARK: - Fingerprint

@Test func dedupeFingerprintPinsExactVector() {
    // shasum -a 256 of the UTF-8 normalized prompt "did you exercise today".
    // If this test breaks, the NORMALIZER changed — that invalidates every
    // stored promptFingerprint, so change it deliberately or not at all.
    #expect(CatalogDedupe.promptFingerprint("Did you exercise today?")
        == "a912cc849e695dbf0b2b69fc28a8b0877aa154730032f9afea7a229657fa93b0")
}

@Test func dedupeFingerprintMatchesForEquivalentPrompts() {
    #expect(CatalogDedupe.promptFingerprint("  DID you exercise\ntoday?!")
        == CatalogDedupe.promptFingerprint("did you exercise today"))
    #expect(CatalogDedupe.promptFingerprint("Did you exercise today?")
        != CatalogDedupe.promptFingerprint("Did you exercise yesterday?"))
}

// MARK: - Matching

@Test func dedupeFirstMatchFindsCatalogEntryByMessyPrompt() {
    let entries = [
        CatalogQuestion(recordName: "cat-1", prompt: "Did you drink water today?",
                        typeRaw: QuestionType.yesNo.rawValue, choices: [], approvedAt: .now),
        CatalogQuestion(recordName: "cat-2", prompt: "How is your energy level?",
                        typeRaw: QuestionType.multipleChoice.rawValue,
                        choices: ["High", "Low"], approvedAt: .now),
    ]
    #expect(CatalogDedupe.firstMatch(prompt: "did you DRINK water today?!", in: entries)?.recordName == "cat-1")
    #expect(CatalogDedupe.firstMatch(prompt: "Did you sleep well?", in: entries) == nil)
}
