import DispatchKit
import Foundation

/// Per-device person → contact link cache (plan 22). Maps a person's synced
/// `uniqueIdentifier` to THIS device's `CNContact.identifier` plus the
/// normalized email/phone match keys captured at link time (for re-matching
/// when the identifier churns). Backed by app-group defaults; NEVER synced —
/// contact identifiers are device-local by Apple's documented contract.
struct ContactLinkCache {
    struct Link: Codable, Equatable {
        var contactIdentifier: String
        var matchKeys: [String]
    }

    private static let key = "contacts.personLinks"
    private let defaults: UserDefaults

    /// Uses app-group defaults by default; UI tests pass their isolated suite.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: StoreLocation.appGroupID)
            ?? .standard
    }

    func link(personID: String, contactIdentifier: String, matchKeys: [String]) {
        var links = loadAll()
        links[personID] = Link(contactIdentifier: contactIdentifier, matchKeys: matchKeys)
        saveAll(links)
    }

    func contactIdentifier(for personID: String) -> String? {
        loadAll()[personID]?.contactIdentifier
    }

    func matchKeys(for personID: String) -> [String] {
        loadAll()[personID]?.matchKeys ?? []
    }

    func unlink(personID: String) {
        var links = loadAll()
        guard links.removeValue(forKey: personID) != nil else { return }
        saveAll(links)
    }

    private func loadAll() -> [String: Link] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: Link].self, from: data)) ?? [:]
    }

    private func saveAll(_ links: [String: Link]) {
        guard let data = try? JSONEncoder().encode(links) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
