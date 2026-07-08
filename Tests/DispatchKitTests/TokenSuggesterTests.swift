import Foundation
import Testing
@testable import DispatchKit

private let sample: [(text: String, usageCount: Int)] = [
    ("Coffee", 10),
    ("Cold brew", 4),
    ("Iced coffee", 7),
    ("Tea", 3),
    ("Matcha", 2),
]

@Test func prefixMatchesRankBeforeSubstringMatches() {
    let result = TokenSuggester.suggest(query: "co", candidates: sample, excluding: [])
    // "Coffee" and "Cold brew" are prefix matches; "Iced coffee" is substring-only.
    #expect(result == ["Coffee", "Cold brew", "Iced coffee"])
}

@Test func usageCountRanksWithinGroup() {
    let candidates: [(text: String, usageCount: Int)] = [
        ("apple pie", 1), ("apricot", 9), ("apple", 5),
    ]
    let result = TokenSuggester.suggest(query: "ap", candidates: candidates, excluding: [])
    #expect(result == ["apricot", "apple", "apple pie"])
}

@Test func alphabeticalTieBreakWithinEqualUsage() {
    let candidates: [(text: String, usageCount: Int)] = [
        ("banana", 2), ("Avocado", 2), ("cherry", 2),
    ]
    let result = TokenSuggester.suggest(query: "", candidates: candidates, excluding: [])
    #expect(result == ["Avocado", "banana", "cherry"])
}

@Test func caseAndDiacriticInsensitiveMatching() {
    let candidates: [(text: String, usageCount: Int)] = [
        ("Café", 5), ("CAFETERIA", 3), ("tea", 1),
    ]
    #expect(TokenSuggester.suggest(query: "cafe", candidates: candidates, excluding: []) == ["Café", "CAFETERIA"])
    #expect(TokenSuggester.suggest(query: "CAFÉ", candidates: candidates, excluding: []) == ["Café", "CAFETERIA"])
}

@Test func excludesAlreadyAddedTokensCaseInsensitively() {
    let result = TokenSuggester.suggest(query: "co", candidates: sample, excluding: ["coffee"])
    #expect(result == ["Cold brew", "Iced coffee"])
}

@Test func exactQueryMatchIsStillSuggested() {
    let result = TokenSuggester.suggest(query: "coffee", candidates: sample, excluding: [])
    #expect(result.contains("Coffee"))
}

@Test func emptyQueryReturnsTopByUsage() {
    let result = TokenSuggester.suggest(query: "", candidates: sample, excluding: [])
    #expect(result == ["Coffee", "Iced coffee", "Cold brew", "Tea", "Matcha"])
}

@Test func whitespaceQueryTreatedAsEmpty() {
    let result = TokenSuggester.suggest(query: "   ", candidates: sample, excluding: [], limit: 2)
    #expect(result == ["Coffee", "Iced coffee"])
}

@Test func limitCapsResults() {
    let candidates = (1...20).map { (text: "token\($0)", usageCount: $0) }
    let result = TokenSuggester.suggest(query: "token", candidates: candidates, excluding: [])
    #expect(result.count == 8)
    #expect(result.first == "token20")
    let limited = TokenSuggester.suggest(query: "token", candidates: candidates, excluding: [], limit: 3)
    #expect(limited == ["token20", "token19", "token18"])
}

@Test func emptyCandidatesYieldNoSuggestions() {
    #expect(TokenSuggester.suggest(query: "a", candidates: [], excluding: []).isEmpty)
    #expect(TokenSuggester.suggest(query: "", candidates: [], excluding: []).isEmpty)
}
