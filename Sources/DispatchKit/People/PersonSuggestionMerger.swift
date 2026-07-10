import Foundation

/// A contact-book match offered to the people typeahead. Pure data — the
/// Contacts-framework fetch lives app-side; DispatchKit only blends/ranks.
public struct ContactMatch: Equatable, Sendable {
    public var displayName: String
    public var thumbnail: Data?
    /// Normalized emails + phone numbers, captured for the per-device link
    /// cache's re-matching when contact identifiers churn.
    public var matchKeys: [String]
    /// This device's `CNContact.identifier`. Consumed ONLY by the per-device
    /// link cache — never stored in synced models (see the person-identity
    /// spec's research constraint).
    public var contactIdentifier: String?

    public init(displayName: String, thumbnail: Data? = nil,
                matchKeys: [String] = [], contactIdentifier: String? = nil) {
        self.displayName = displayName
        self.thumbnail = thumbnail
        self.matchKeys = matchKeys
        self.contactIdentifier = contactIdentifier
    }
}

/// One typeahead chip: history/registry entries first, then contacts.
public struct PersonSuggestion: Equatable, Sendable {
    public var text: String
    public var thumbnail: Data?
    public var isContact: Bool

    public init(text: String, thumbnail: Data? = nil, isContact: Bool = false) {
        self.text = text
        self.thumbnail = thumbnail
        self.isContact = isContact
    }
}

/// Blends history/registry suggestions with contact matches for the people
/// typeahead (plan 22). History first; contacts are deduped case- and
/// diacritic-insensitively against history AND against each other by
/// identical display text (duplicate cards → one chip, preferring the one
/// with a thumbnail); the whole list is capped.
public enum PersonSuggestionMerger {
    public static func blend(history: [String], contacts: [ContactMatch],
                             cap: Int = 8) -> [PersonSuggestion] {
        var suggestions = history.map { PersonSuggestion(text: $0, isContact: false) }
        var seen = Set(history.map(PersonResolver.normalize))

        var bestByText: [String: ContactMatch] = [:]
        var order: [String] = []
        for contact in contacts {
            let key = PersonResolver.normalize(contact.displayName)
            guard !key.isEmpty else { continue }
            if let existing = bestByText[key] {
                if existing.thumbnail == nil, contact.thumbnail != nil {
                    bestByText[key] = contact
                }
            } else {
                bestByText[key] = contact
                order.append(key)
            }
        }
        for key in order where !seen.contains(key) {
            guard let contact = bestByText[key] else { continue }
            seen.insert(key)
            suggestions.append(PersonSuggestion(text: contact.displayName,
                                                thumbnail: contact.thumbnail,
                                                isContact: true))
        }
        return Array(suggestions.prefix(cap))
    }
}
