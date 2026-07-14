import DispatchKit
import Foundation
import Observation
import SwiftData

/// View-facing state for the community question catalog. All CloudKit work
/// happens inside the provider off the main actor; this store only holds
/// results. Search is client-side over the loaded entries (catalog scale is
/// small; avoids requiring a SEARCHABLE Console index on `prompt`).
@Observable
@MainActor
final class CatalogStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var entries: [CatalogQuestion] = []
    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false
    var searchText = ""

    private let provider: any CatalogProviding
    private var cursor: CatalogQueryCursor?

    var hasMore: Bool { cursor != nil }

    /// Per-device submission throttle state (plan 38). `UserDefaults.standard`
    /// deliberately — NOT iCloud KVS: syncing the counter would punish
    /// multi-device users for a control that provides zero security anyway
    /// (see `SubmissionThrottle`'s doc comment).
    static let submissionTimestampsKey = "catalog.submissionTimestamps"
    private(set) var submissionTimestamps: [Date]

    init(provider: any CatalogProviding = CatalogStore.makeProvider()) {
        self.provider = provider
        // UI-test hook: seed (or reset — defaults persist across launches on
        // a simulator) the throttle state so quota tests don't need five
        // round-trip submissions.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") || arguments.contains("--mock-sensors") {
            let count = Int(ProcessInfo.processInfo.environment["CATALOG_SEEDED_SUBMISSIONS"] ?? "") ?? 0
            let seeded = (0..<count).map { Date.now.addingTimeInterval(-Double($0) * 60) }
            UserDefaults.standard.set(seeded, forKey: Self.submissionTimestampsKey)
            // The own-submission fingerprint memory (plan 42) also lives in
            // UserDefaults.standard, which the app's `--ui-testing` suite wipe
            // does NOT reach — so a fixed-prompt submission would stick across
            // launches and every later run would hit `.alreadySubmitted`. Reset
            // it here alongside the throttle so submission tests start clean.
            UserDefaults.standard.removeObject(forKey: Self.submittedFingerprintsKey)
        }
        submissionTimestamps =
            (UserDefaults.standard.array(forKey: Self.submissionTimestampsKey) as? [Date]) ?? []
    }

    var submissionsRemaining: Int {
        SubmissionThrottle(timestamps: submissionTimestamps).remaining(now: .now)
    }

    var nextSubmissionAllowed: Date? {
        SubmissionThrottle(timestamps: submissionTimestamps).nextAllowed(now: .now)
    }

    /// Stubbed under UI-test launch args — UI tests never touch real CloudKit.
    static func makeProvider() -> any CatalogProviding {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") || arguments.contains("--mock-sensors") {
            return StubCatalogProvider()
        }
        return CloudKitCatalogProvider()
    }

    var filteredEntries: [CatalogQuestion] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.prompt.localizedCaseInsensitiveContains(query)
                || $0.tags.contains { tag in tag.localizedCaseInsensitiveContains(query) }
        }
    }

    func loadFirstPage() async {
        guard phase != .loading else { return }
        phase = .loading
        do {
            let (entries, cursor) = try await provider.approvedQuestions(after: nil)
            self.entries = entries
            self.cursor = cursor
            phase = .loaded
        } catch {
            entries = []
            cursor = nil
            phase = .failed(error.localizedDescription)
        }
    }

    func loadNextPage() async {
        guard let cursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let (more, nextCursor) = try await provider.approvedQuestions(after: cursor)
            // Dedupe on recordName in case a page boundary shifted server-side.
            let known = Set(entries.map(\.recordName))
            entries.append(contentsOf: more.filter { !known.contains($0.recordName) })
            self.cursor = nextCursor
        } catch {
            // Keep what we have; the footer button lets the user retry.
        }
    }

    func accountStatus() async -> CatalogAccountStatus {
        await provider.accountStatus()
    }

    /// Validate + normalize + duplicate-check + create a SubmittedQuestion
    /// record. Throws `CatalogProviderError.validation` with all structural
    /// problems, `.duplicate(existing:)` when the prompt matches a catalog
    /// entry (plan 42 — the form offers "Add to My Questions" instead), or
    /// `.alreadySubmitted` when this device already submitted the prompt.
    /// The input configuration (plan 41) is optional: style/default answer
    /// are number-only, placeholder applies to any type, and the bounds ride
    /// along with the style (already parsed to finite Doubles by the form).
    func submit(prompt: String, typeRaw: Int, choices: [String], creditName: String?,
                inputStyle: String? = nil, defaultAnswer: String? = nil,
                placeholder: String? = nil, inputMin: Double? = nil,
                inputMax: Double? = nil, inputStep: Double? = nil) async throws {
        // Throttle first (plan 38): exhausted quota fails before validation
        // or the network, and a timestamp is recorded only after the provider
        // succeeds — failed submits never burn a slot.
        let now = Date.now
        let throttle = SubmissionThrottle(timestamps: submissionTimestamps)
        guard throttle.canSubmit(now: now) else {
            throw CatalogProviderError.throttled(
                until: throttle.nextAllowed(now: now) ?? now.addingTimeInterval(SubmissionThrottle.window)
            )
        }
        let errors = CatalogValidation.validate(
            prompt: prompt, typeRaw: typeRaw, choices: choices, creditName: creditName,
            inputStyle: inputStyle, defaultAnswer: defaultAnswer, placeholder: placeholder
        )
        guard errors.isEmpty else { throw CatalogProviderError.validation(errors) }
        let normalized = CatalogValidation.normalized(
            prompt: prompt, choices: choices, creditName: creditName,
            inputStyle: inputStyle, defaultAnswer: defaultAnswer, placeholder: placeholder
        )
        // Duplicate pre-check (plan 42): UX friction only — dispatch-mod is
        // the enforcement. Loaded entries first (free, covers un-backfilled
        // records), then a targeted fingerprint query for entries beyond the
        // loaded pages. Lookup failures never block a submission.
        let fingerprint = CatalogDedupe.promptFingerprint(normalized.prompt)
        if let existing = CatalogDedupe.firstMatch(prompt: normalized.prompt, in: entries) {
            throw CatalogProviderError.duplicate(existing: existing)
        }
        if let existing = await provider.catalogQuestion(matchingFingerprint: fingerprint) {
            throw CatalogProviderError.duplicate(existing: existing)
        }
        if Self.submittedFingerprints().contains(fingerprint) {
            throw CatalogProviderError.alreadySubmitted
        }
        try await provider.submit(
            prompt: normalized.prompt, typeRaw: typeRaw,
            choices: normalized.choices, creditName: normalized.creditName,
            inputStyle: normalized.inputStyle, defaultAnswer: normalized.defaultAnswer,
            placeholder: normalized.placeholder,
            inputMin: inputMin, inputMax: inputMax, inputStep: inputStep
        )
        let recorded = throttle.recording(now: now)
        submissionTimestamps = recorded.timestamps
        UserDefaults.standard.set(recorded.timestamps, forKey: Self.submissionTimestampsKey)
        Self.recordSubmittedFingerprint(fingerprint)
    }

    // MARK: - Own-submission memory (plan 42)

    /// Fingerprints of prompts this device successfully submitted, newest
    /// last, capped. Per-device friction against accidental resubmission
    /// (like plan 38's throttle, honest about being bypassable) — a distinct
    /// UserDefaults key from the throttle's timestamps.
    static let submittedFingerprintsKey = "catalog.submittedFingerprints"
    static let submittedFingerprintsCap = 50

    static func submittedFingerprints(
        defaults: UserDefaults = .standard
    ) -> [String] {
        defaults.stringArray(forKey: submittedFingerprintsKey) ?? []
    }

    static func recordSubmittedFingerprint(
        _ fingerprint: String, defaults: UserDefaults = .standard
    ) {
        var fingerprints = submittedFingerprints(defaults: defaults)
        guard !fingerprints.contains(fingerprint) else { return }
        fingerprints.append(fingerprint)
        if fingerprints.count > submittedFingerprintsCap {
            fingerprints.removeFirst(fingerprints.count - submittedFingerprintsCap)
        }
        defaults.set(fingerprints, forKey: submittedFingerprintsKey)
    }

    func flag(catalogRecordName: String, reason: String) async throws {
        let errors = CatalogValidation.validateFlagReason(reason)
        guard errors.isEmpty else { throw CatalogProviderError.validation(errors) }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        try await provider.flag(
            catalogRecordName: catalogRecordName,
            reason: trimmed.isEmpty ? "No reason given" : trimmed
        )
    }

    /// "Add to my questions": creates an ordinary LOCAL Question with a
    /// FRESH UUID (Question() generates one) — catalog identity never
    /// collides with sync identity, and no local schema changes are needed.
    /// Returns the created question, or nil when an identical prompt+type
    /// already exists (adding twice is a no-op, not a duplicate).
    @discardableResult
    func addToMyQuestions(_ entry: CatalogQuestion, context: ModelContext) -> Question? {
        guard let type = entry.type else { return nil }
        let existing = (try? context.fetch(FetchDescriptor<Question>())) ?? []
        if existing.contains(where: { $0.prompt == entry.prompt && $0.typeRaw == entry.typeRaw }) {
            return nil
        }
        let question = QuestionAdmin.makeQuestion(
            prompt: entry.prompt, type: type, choices: entry.choices,
            placeholder: entry.placeholder, kinds: [.regular], after: existing,
            defaultAnswer: entry.defaultAnswer, inputStyle: entry.inputStyle,
            inputMin: entry.inputMin, inputMax: entry.inputMax, inputStep: entry.inputStep
        )
        context.insert(question)
        try? context.save()
        return question
    }
}
