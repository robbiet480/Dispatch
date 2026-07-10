import Contacts
import DispatchKit
import Foundation
import os

private let contactsLog = Logger(subsystem: "io.robbie.Dispatch", category: "contacts")

/// Source of contact-book matches for the people typeahead (plan 22).
/// Implementations must be safe to call off-main and must never present
/// permission dialogs from `matches(prefix:)` — access is only ever requested
/// by the explicit `requestAccess()` the settings toggle / inline offer runs.
protocol ContactSuggestionProviding: Sendable {
    /// Prefix matches (given/family/nickname/full name) against the user's
    /// unified contacts. Empty/whitespace prefix → `[]` (empty query is
    /// history-only). Unauthorized/denied/errors → `[]`, silently.
    func matches(prefix: String) async -> [ContactMatch]
    /// The one standard `CNContactStore.requestAccess` call. Returns whether
    /// access was granted (full and limited are both "granted").
    func requestAccess() async -> Bool
    /// Live thumbnail for a linked contact; resolution order per spec:
    /// cached identifier → re-match by email/phone keys → nil (caller
    /// unlinks silently on total failure).
    func thumbnail(identifier: String?, matchKeys: [String]) async -> Data?
}

/// Namespace for the toggle/offer defaults keys and provider selection.
enum ContactSuggestions {
    /// "Suggest from Contacts" toggle — default OFF per spec.
    static let enabledKey = "contacts.suggestionsEnabled"
    /// One-time inline offer under a people question — set once acted on.
    static let inlineOfferSeenKey = "contacts.inlineOfferSeen"

    static var isTestEnvironment: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--mock-sensors") || arguments.contains("--ui-testing")
    }

    /// Stub under --mock-sensors/--ui-testing (no permission dialogs, fixed
    /// fixtures), the CNContactStore implementation otherwise.
    static func makeProvider() -> any ContactSuggestionProviding {
        isTestEnvironment ? StubContactSuggestionProvider() : CNContactSuggestionProvider()
    }

    /// Whether contacts access is currently denied/restricted — used for the
    /// on-but-denied settings hint. Never prompts.
    static var isDenied: Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .denied, .restricted: true
        default: false
        }
    }
}

/// The real provider. An actor: every store access runs off-main, and the
/// per-appearance fetch cache is data-race-free by construction. iOS
/// full-vs-limited access is transparent — one code path over whatever the
/// store returns. No continuations anywhere in this path (Apple's async
/// `requestAccess` overload is used as-is).
actor CNContactSuggestionProvider: ContactSuggestionProviding {
    private var cache: [Entry]?

    private struct Entry {
        var match: ContactMatch
        /// Normalized name fragments the prefix is checked against.
        var nameKeys: [String]
    }

    private static var isAuthorized: Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: true
        default: false
        }
    }

    func matches(prefix: String) async -> [ContactMatch] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Self.isAuthorized else { return [] }
        let query = PersonResolver.normalize(trimmed)
        return entries().filter { entry in
            entry.nameKeys.contains { $0.hasPrefix(query) }
        }.map(\.match)
    }

    func requestAccess() async -> Bool {
        do {
            return try await CNContactStore().requestAccess(for: .contacts)
        } catch {
            contactsLog.error("contacts access request failed: \(error, privacy: .public)")
            return false
        }
    }

    func thumbnail(identifier: String?, matchKeys: [String]) async -> Data? {
        guard Self.isAuthorized else { return nil }
        let store = CNContactStore()
        let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
        if let identifier,
           let contact = try? store.unifiedContact(withIdentifier: identifier, keysToFetch: keys),
           let data = contact.thumbnailImageData {
            return data
        }
        // Identifier churned or carried no photo — re-match by email/phone.
        guard !matchKeys.isEmpty else { return nil }
        for entry in entries() where !Set(entry.match.matchKeys).isDisjoint(with: matchKeys) {
            if let data = entry.match.thumbnail { return data }
        }
        return nil
    }

    /// Fetches (once per provider instance — providers are created per field
    /// appearance) and caches all unified contacts as match entries.
    private func entries() -> [Entry] {
        if let cache { return cache }
        var built: [Entry] = []
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        do {
            try CNContactStore().enumerateContacts(with: request) { contact, _ in
                guard let entry = Self.entry(for: contact) else { return }
                built.append(entry)
            }
        } catch {
            contactsLog.error("contact enumeration failed: \(error, privacy: .public)")
        }
        cache = built
        return built
    }

    private static func entry(for contact: CNContact) -> Entry? {
        let displayName = CNContactFormatter.string(from: contact, style: .fullName)
            ?? [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        guard !displayName.isEmpty else { return nil }
        let emails = contact.emailAddresses.map {
            ($0.value as String).lowercased().trimmingCharacters(in: .whitespaces)
        }
        let phones = contact.phoneNumbers.map { normalizePhone($0.value.stringValue) }
        let matchKeys = (emails + phones).filter { !$0.isEmpty }
        let match = ContactMatch(displayName: displayName,
                                 thumbnail: contact.thumbnailImageData,
                                 matchKeys: matchKeys,
                                 contactIdentifier: contact.identifier)
        var nameKeys = [displayName, contact.givenName, contact.familyName, contact.nickname]
            .filter { !$0.isEmpty }
            .map(PersonResolver.normalize)
        // Also match on later words of the full name ("smith" finds "Jo Smith").
        nameKeys += PersonResolver.normalize(displayName)
            .split(separator: " ").dropFirst().map(String.init)
        return Entry(match: match, nameKeys: nameKeys)
    }

    private static func normalizePhone(_ raw: String) -> String {
        raw.filter { $0.isNumber || $0 == "+" }
    }
}

/// Deterministic stub used under --mock-sensors/--ui-testing: no store, no
/// dialogs. Fixture names are prefixed "Stub" so UI tests can type "Stub"
/// and assert blended contact chips render.
struct StubContactSuggestionProvider: ContactSuggestionProviding {
    static let fixtures: [ContactMatch] = [
        ContactMatch(displayName: "Stub Contact",
                     thumbnail: nil,
                     matchKeys: ["stub@example.com", "+15551234567"],
                     contactIdentifier: "stub-contact-1"),
        ContactMatch(displayName: "Stub Companion",
                     thumbnail: nil,
                     matchKeys: ["companion@example.com"],
                     contactIdentifier: "stub-contact-2"),
    ]

    func matches(prefix: String) async -> [ContactMatch] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let query = PersonResolver.normalize(trimmed)
        return Self.fixtures.filter {
            PersonResolver.normalize($0.displayName).hasPrefix(query)
        }
    }

    func requestAccess() async -> Bool { true }

    func thumbnail(identifier: String?, matchKeys: [String]) async -> Data? { nil }
}
