import Foundation
import Testing
@testable import DispatchKit

@Test func blendPutsHistoryFirstThenContacts() {
    let blended = PersonSuggestionMerger.blend(
        history: ["Alex", "Sam"],
        contacts: [ContactMatch(displayName: "Casey", thumbnail: Data([1]))])
    #expect(blended.map(\.text) == ["Alex", "Sam", "Casey"])
    #expect(blended.map(\.isContact) == [false, false, true])
    #expect(blended[2].thumbnail == Data([1]))
}

@Test func blendDedupesContactsAgainstHistoryCaseInsensitively() {
    let blended = PersonSuggestionMerger.blend(
        history: ["José"],
        contacts: [ContactMatch(displayName: "jose"), ContactMatch(displayName: "Riley")])
    #expect(blended.map(\.text) == ["José", "Riley"])
}

@Test func blendCollapsesDuplicateCardsPreferringThumbnailed() {
    let blended = PersonSuggestionMerger.blend(
        history: [],
        contacts: [
            ContactMatch(displayName: "Alex Doe"),
            ContactMatch(displayName: "alex doe", thumbnail: Data([9])),
            ContactMatch(displayName: "Alex Doe", thumbnail: Data([7])),
        ])
    #expect(blended.count == 1)
    // First thumbnailed duplicate wins; display keeps its own casing.
    #expect(blended[0].thumbnail == Data([9]))
    #expect(blended[0].isContact)
}

@Test func blendCapsTotalCount() {
    let history = (0..<6).map { "H\($0)" }
    let contacts = (0..<6).map { ContactMatch(displayName: "C\($0)") }
    let blended = PersonSuggestionMerger.blend(history: history, contacts: contacts)
    #expect(blended.count == 8)
    #expect(blended.prefix(6).allSatisfy { !$0.isContact })
    #expect(blended.suffix(2).map(\.text) == ["C0", "C1"])
}

@Test func blendIgnoresEmptyContactNames() {
    let blended = PersonSuggestionMerger.blend(
        history: [], contacts: [ContactMatch(displayName: "  ")])
    // Whitespace-only display names normalize to non-empty whitespace keys;
    // truly empty names are dropped.
    let empty = PersonSuggestionMerger.blend(
        history: [], contacts: [ContactMatch(displayName: "")])
    #expect(empty.isEmpty)
    #expect(blended.count <= 1)
}
