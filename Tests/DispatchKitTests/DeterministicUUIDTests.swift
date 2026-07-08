import Foundation
import Testing
@testable import DispatchKit

// MARK: - UUIDv5 implementation

@Test func v5MatchesReferenceImplementation() {
    // Known-good vector computed with Python:
    //   uuid.uuid5(uuid.NAMESPACE_DNS, "www.example.org")
    //   == 74738ff5-5367-5958-9aee-98fffdcd1876
    let dnsNamespace = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
    let uuid = UUID(v5Namespace: dnsNamespace, name: "www.example.org")
    #expect(uuid.uuidString == "74738FF5-5367-5958-9AEE-98FFFDCD1876")
}

@Test func v5MatchesDispatchReferenceVectors() {
    // Computed with Python uuid.uuid5 against the frozen Dispatch namespace:
    //   uuid.uuid5(UUID("fbd78042-1afa-45f8-99b5-bc884958b2d1"),
    //              "io.robbie.Dispatch.default-question.<slug>")
    let expected: [String: String] = [
        "how-did-you-sleep": "86E9C690-11B4-569E-8D0A-E6C4877CA99A",
        "are-you-working": "6BCB574C-57B1-5593-B392-B7608B42FD92",
        "what-are-you-doing": "73F32134-35A3-5994-9D2C-4924F589EF66",
        "where-are-you": "7F06307F-4AD8-52EB-867A-7216C4E84036",
        "who-are-you-with": "9E55B97E-CFCC-5E2C-985B-458F9CFB41BB",
        "how-many-coffees": "20F27A3B-709A-5E37-B4A2-F04C316891CF",
        "what-did-you-learn": "30FF77F6-D3C6-58CB-BEEF-17294FF32969",
    ]
    for seed in DefaultQuestions.all {
        #expect(seed.identifier == expected[seed.slug], "slug \(seed.slug)")
    }
}

@Test func v5IsDeterministic() {
    let a = UUID(v5Namespace: DefaultQuestions.namespace, name: "io.robbie.Dispatch.default-question.are-you-working")
    let b = UUID(v5Namespace: DefaultQuestions.namespace, name: "io.robbie.Dispatch.default-question.are-you-working")
    #expect(a == b)
    #expect(DefaultQuestions.all[1].identifier == a.uuidString)
}

@Test func v5IsDistinctAcrossSlugs() {
    let ids = Set(DefaultQuestions.all.map(\.identifier))
    #expect(ids.count == DefaultQuestions.all.count)
}

@Test func namespaceIsFrozen() {
    #expect(DefaultQuestions.namespace == UUID(uuidString: "FBD78042-1AFA-45F8-99B5-BC884958B2D1"))
}

// MARK: - Catalog / legacy mapping

@Test func legacyIndexTableMapsToSlugsNotPrompts() {
    #expect(DefaultQuestions.migratedIdentifier(forLegacyID: "default-question-0")
        == DefaultQuestions.all[0].identifier)
    #expect(DefaultQuestions.migratedIdentifier(forLegacyID: "default-question-6")
        == DefaultQuestions.all[6].identifier)
    #expect(DefaultQuestions.migratedIdentifier(forLegacyID: "default-question-7") == nil)
    #expect(DefaultQuestions.migratedIdentifier(forLegacyID: "default-question-") == nil)
    #expect(DefaultQuestions.migratedIdentifier(forLegacyID: "default-question--1") == nil)
    #expect(DefaultQuestions.migratedIdentifier(forLegacyID: UUID().uuidString) == nil)
}
