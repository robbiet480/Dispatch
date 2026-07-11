import CloudKit
import DispatchKit
import Foundation
import OSLog

private let catalogLog = Logger(subsystem: "io.robbie.Dispatch", category: "catalog")

/// Moderation boundary (plan 20): the app NEVER writes `CatalogQuestion`
/// records. This provider can create `SubmittedQuestion` and `QuestionFlag`
/// records only; catalog entries are created exclusively by the
/// server-to-server key via `dispatch-mod`. Keep it that way — approval
/// happens outside the app by construction, not by policy.

/// Opaque pagination token. Wraps `CKQueryOperation.Cursor` for the CloudKit
/// provider and a plain offset for the UI-test stub.
struct CatalogQueryCursor: @unchecked Sendable {
    let value: Any
}

enum CatalogAccountStatus: Sendable {
    case available
    case unavailable(reason: String)
}

enum CatalogProviderError: LocalizedError {
    case network(underlying: String)
    case validation([CatalogValidationError])
    /// Plan 38: the per-device submission throttle is exhausted. Thrown by
    /// `CatalogStore.submit` before the provider is touched, so scripted
    /// callers hit the same wall as the UI. Friction, not security — see
    /// `SubmissionThrottle`.
    case throttled(until: Date)

    var errorDescription: String? {
        switch self {
        case .network(let underlying): underlying
        case .validation(let errors): errors.map(\.message).joined(separator: " ")
        case .throttled(let until):
            "Daily limit reached — try again after \(until.formatted(date: .omitted, time: .shortened))."
        }
    }
}

protocol CatalogProviding: Sendable {
    /// One page of approved catalog entries, newest approval first.
    /// `cursor == nil` requests the first page; a nil returned cursor means
    /// the listing is exhausted.
    func approvedQuestions(
        after cursor: CatalogQueryCursor?
    ) async throws -> (entries: [CatalogQuestion], cursor: CatalogQueryCursor?)

    /// Create a SubmittedQuestion record (values already validated/normalized).
    /// The plan-41 input configuration is optional and nil-omitted.
    func submit(prompt: String, typeRaw: Int, choices: [String], creditName: String?,
                inputStyle: String?, defaultAnswer: String?, placeholder: String?,
                inputMin: Double?, inputMax: Double?, inputStep: Double?) async throws

    /// Create a QuestionFlag record against a catalog entry.
    func flag(catalogRecordName: String, reason: String) async throws

    /// Whether writes are possible (submitting/flagging needs an iCloud
    /// account; browsing the public database does not).
    func accountStatus() async -> CatalogAccountStatus
}

/// Real provider: the existing CloudKit container's PUBLIC database. No new
/// entitlements — the public DB rides the container the private sync DB
/// already uses.
final class CloudKitCatalogProvider: CatalogProviding {
    static let pageSize = 25

    private var database: CKDatabase {
        CKContainer(identifier: SyncPolicy.containerIdentifier).publicCloudDatabase
    }

    func approvedQuestions(
        after cursor: CatalogQueryCursor?
    ) async throws -> (entries: [CatalogQuestion], cursor: CatalogQueryCursor?) {
        let matchResults: [(CKRecord.ID, Result<CKRecord, Error>)]
        let nextCursor: CKQueryOperation.Cursor?
        do {
            if let ckCursor = cursor?.value as? CKQueryOperation.Cursor {
                (matchResults, nextCursor) = try await database.records(
                    continuingMatchFrom: ckCursor, resultsLimit: Self.pageSize
                )
            } else {
                let query = CKQuery(
                    recordType: CatalogRecordType.catalogQuestion,
                    predicate: NSPredicate(value: true)
                )
                query.sortDescriptors = [NSSortDescriptor(key: "approvedAt", ascending: false)]
                (matchResults, nextCursor) = try await database.records(
                    matching: query, resultsLimit: Self.pageSize
                )
            }
        } catch {
            // Before the Console setup / first approve, the CatalogQuestion
            // record type doesn't exist in this environment and the query
            // errors. That's an EMPTY catalog, not a user-facing failure.
            if Self.isMissingRecordType(error) {
                catalogLog.info("CatalogQuestion record type missing (pre-setup); showing empty catalog: \(error)")
                return ([], nil)
            }
            throw CatalogProviderError.network(underlying: Self.friendlyMessage(for: error))
        }

        let entries = matchResults.compactMap { _, result -> CatalogQuestion? in
            guard let record = try? result.get() else { return nil }
            return Self.catalogQuestion(from: record)
        }
        return (entries, nextCursor.map { CatalogQueryCursor(value: $0) })
    }

    func submit(prompt: String, typeRaw: Int, choices: [String], creditName: String?,
                inputStyle: String?, defaultAnswer: String?, placeholder: String?,
                inputMin: Double?, inputMax: Double?, inputStep: Double?) async throws {
        let submission = SubmittedQuestion(
            recordName: UUID().uuidString, prompt: prompt, typeRaw: typeRaw,
            choices: choices, creditName: creditName, submittedAt: .now,
            inputStyle: inputStyle, defaultAnswer: defaultAnswer, placeholder: placeholder,
            inputMin: inputMin, inputMax: inputMax, inputStep: inputStep
        )
        let record = CKRecord(
            recordType: CatalogRecordType.submittedQuestion,
            recordID: CKRecord.ID(recordName: submission.recordName)
        )
        Self.apply(fields: submission.fields, to: record)
        do {
            _ = try await database.save(record)
        } catch {
            throw CatalogProviderError.network(underlying: Self.friendlyMessage(for: error))
        }
    }

    func flag(catalogRecordName: String, reason: String) async throws {
        let flag = QuestionFlag(
            recordName: UUID().uuidString, catalogRecordName: catalogRecordName,
            reason: reason, flaggedAt: .now
        )
        let record = CKRecord(
            recordType: CatalogRecordType.questionFlag,
            recordID: CKRecord.ID(recordName: flag.recordName)
        )
        Self.apply(fields: flag.fields, to: record)
        do {
            _ = try await database.save(record)
        } catch {
            throw CatalogProviderError.network(underlying: Self.friendlyMessage(for: error))
        }
    }

    func accountStatus() async -> CatalogAccountStatus {
        do {
            let status = try await CKContainer(identifier: SyncPolicy.containerIdentifier).accountStatus()
            switch status {
            case .available:
                return .available
            case .noAccount:
                return .unavailable(reason: "Sign in to iCloud to submit or flag questions. Browsing works without an account.")
            case .restricted, .couldNotDetermine, .temporarilyUnavailable:
                return .unavailable(reason: "iCloud isn't available right now. Browsing still works; try submitting later.")
            @unknown default:
                return .unavailable(reason: "iCloud isn't available right now.")
            }
        } catch {
            return .unavailable(reason: "iCloud isn't available right now.")
        }
    }

    // MARK: - CKRecord ↔ kit value mapping

    /// The kit's typed field dictionaries keep DispatchKit CloudKit-free;
    /// this is the app-side bridge (write side: submissions + flags ONLY).
    static func apply(fields: [String: CatalogFieldValue], to record: CKRecord) {
        for (key, value) in fields {
            switch value {
            case .string(let string): record[key] = string as CKRecordValue
            case .int(let int): record[key] = int as CKRecordValue
            case .double(let double): record[key] = double as CKRecordValue
            case .date(let date): record[key] = date as CKRecordValue
            case .stringList(let list): record[key] = list as CKRecordValue
            }
        }
    }

    static func catalogQuestion(from record: CKRecord) -> CatalogQuestion? {
        var fields: [String: CatalogFieldValue] = [:]
        if let prompt = record["prompt"] as? String { fields["prompt"] = .string(prompt) }
        if let typeRaw = record["typeRaw"] as? Int64 {
            fields["typeRaw"] = .int(Int(typeRaw))
        } else if let typeRaw = record["typeRaw"] as? Int {
            fields["typeRaw"] = .int(typeRaw)
        }
        if let choicesJSON = record["choicesJSON"] as? String { fields["choicesJSON"] = .string(choicesJSON) }
        if let credit = record["credit"] as? String { fields["credit"] = .string(credit) }
        if let approvedAt = record["approvedAt"] as? Date { fields["approvedAt"] = .date(approvedAt) }
        if let tags = record["tags"] as? [String] { fields["tags"] = .stringList(tags) }
        // Input configuration (plan 41) — optional on every record.
        for key in ["inputStyle", "defaultAnswer", "placeholder"] {
            if let string = record[key] as? String { fields[key] = .string(string) }
        }
        for key in ["inputMin", "inputMax", "inputStep"] {
            if let double = record[key] as? Double { fields[key] = .double(double) }
        }
        return CatalogQuestion(recordName: record.recordID.recordName, fields: fields)
    }

    /// CloudKit reports a query against a record type that doesn't exist in
    /// the environment's schema as `.invalidArguments` (BAD_REQUEST) with a
    /// server message like "Did not find record type: CatalogQuestion";
    /// `.unknownItem` is accepted too (belt-and-braces — some paths report
    /// missing schema objects with it). Matched on the message so a genuinely
    /// malformed query still surfaces as an error.
    static func isMissingRecordType(_ error: Error) -> Bool {
        guard let ckError = error as? CKError,
              ckError.code == .invalidArguments || ckError.code == .unknownItem else { return false }
        let details = [
            ckError.localizedDescription,
            ckError.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
            ckError.userInfo["ServerErrorDescription"] as? String,
            ckError.userInfo["CKErrorServerDescriptionKey"] as? String,
        ].compactMap { $0 }.joined(separator: " ").lowercased()
        return details.contains("record type")
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .networkUnavailable, .networkFailure:
                return "The catalog needs a network connection."
            case .notAuthenticated:
                return "Sign in to iCloud to do that. Browsing works without an account."
            case .requestRateLimited, .zoneBusy, .serviceUnavailable:
                return "iCloud is busy — try again in a moment."
            default:
                break
            }
        }
        return "The catalog couldn't reach iCloud. Try again later."
    }
}

/// UI-test stub (selected under --ui-testing/--mock-sensors): fixed entries,
/// in-memory submissions/flags, no CloudKit anywhere near the test suite.
final class StubCatalogProvider: CatalogProviding, @unchecked Sendable {
    static let stubEntries: [CatalogQuestion] = [
        CatalogQuestion(
            recordName: "stub-catalog-1", prompt: "Did you drink water today?",
            typeRaw: QuestionType.yesNo.rawValue, choices: [], credit: "Stub Author",
            approvedAt: Date(timeIntervalSinceReferenceDate: 800_000_000), tags: ["health"]
        ),
        CatalogQuestion(
            recordName: "stub-catalog-2", prompt: "How is your energy level?",
            typeRaw: QuestionType.multipleChoice.rawValue, choices: ["High", "Medium", "Low"],
            credit: nil, approvedAt: Date(timeIntervalSinceReferenceDate: 799_000_000), tags: []
        ),
        CatalogQuestion(
            recordName: "stub-catalog-3", prompt: "What did you eat?",
            typeRaw: QuestionType.tokens.rawValue, choices: [], credit: nil,
            approvedAt: Date(timeIntervalSinceReferenceDate: 798_000_000), tags: ["food"]
        ),
        // Fully configured number entry (plan 41): exercises the
        // add-to-my-questions input-config mapping in UI tests.
        CatalogQuestion(
            recordName: "stub-catalog-4", prompt: "How stressed are you?",
            typeRaw: QuestionType.number.rawValue, choices: [], credit: nil,
            approvedAt: Date(timeIntervalSinceReferenceDate: 797_000_000), tags: ["mood"],
            inputStyle: "scale", defaultAnswer: "3", placeholder: "1 to 5",
            inputMin: 1, inputMax: 5, inputStep: 1
        ),
    ]

    private(set) var submissions: [(prompt: String, typeRaw: Int, choices: [String], creditName: String?,
                                    inputStyle: String?, defaultAnswer: String?, placeholder: String?,
                                    inputMin: Double?, inputMax: Double?, inputStep: Double?)] = []
    private(set) var flags: [(catalogRecordName: String, reason: String)] = []

    func approvedQuestions(
        after cursor: CatalogQueryCursor?
    ) async throws -> (entries: [CatalogQuestion], cursor: CatalogQueryCursor?) {
        // Single page; a non-nil cursor request returns the empty tail.
        if cursor != nil { return ([], nil) }
        return (Self.stubEntries, nil)
    }

    func submit(prompt: String, typeRaw: Int, choices: [String], creditName: String?,
                inputStyle: String?, defaultAnswer: String?, placeholder: String?,
                inputMin: Double?, inputMax: Double?, inputStep: Double?) async throws {
        submissions.append((prompt, typeRaw, choices, creditName,
                            inputStyle, defaultAnswer, placeholder,
                            inputMin, inputMax, inputStep))
    }

    func flag(catalogRecordName: String, reason: String) async throws {
        flags.append((catalogRecordName, reason))
    }

    func accountStatus() async -> CatalogAccountStatus { .available }
}
