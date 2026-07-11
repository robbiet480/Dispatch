import Foundation

/// Community question catalog value types (plan 20).
///
/// Design decision: DispatchKit stays **CloudKit-import-free**. Records are
/// modeled as plain value types plus a typed field dictionary
/// (`[String: CatalogFieldValue]`). The app converts those dictionaries to
/// `CKRecord` values; `dispatch-mod` converts them to CloudKit Web Services
/// JSON. Neither direction requires the kit to link CloudKit, and the mapping
/// itself is pure and unit-testable.
///
/// Moderation boundary (the design's heart): `CatalogQuestion` records are
/// created ONLY by the server-to-server key via `dispatch-mod`. Nothing in
/// the app writes `CatalogQuestion` — clients submit `SubmittedQuestion`
/// records and approval is the mod tool copying a submission into the
/// catalog. `CatalogQuestion.fields` exists for the mod tool's approve path;
/// the app only ever *reads* catalog records.
public enum CatalogRecordType {
    public static let submittedQuestion = "SubmittedQuestion"
    public static let catalogQuestion = "CatalogQuestion"
    public static let questionFlag = "QuestionFlag"
}

/// A typed CloudKit-free field value. The narrow set matches what the three
/// catalog record shapes actually need.
public enum CatalogFieldValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case date(Date)
    case stringList([String])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var dateValue: Date? {
        if case .date(let value) = self { return value }
        return nil
    }

    public var stringListValue: [String]? {
        if case .stringList(let value) = self { return value }
        return nil
    }
}

/// Choices travel as a JSON-encoded string field (`choicesJSON`) so the
/// record shape stays a flat scalar and Console permission/index handling
/// stays trivial. Encoding is deterministic (plain array of strings).
public enum CatalogChoicesJSON {
    public static func encode(_ choices: [String]) -> String {
        guard let data = try? JSONEncoder().encode(choices),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    public static func decode(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let choices = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return choices
    }
}

/// An approved, world-readable catalog entry. Created exclusively by the
/// server-to-server key (see the moderation boundary note above).
public struct CatalogQuestion: Equatable, Sendable, Identifiable {
    public var recordName: String
    public var prompt: String
    public var typeRaw: Int
    public var choices: [String]
    public var credit: String?
    public var approvedAt: Date
    public var tags: [String]
    /// Input configuration (plan 41) — all optional and lenient so
    /// pre-plan-41 records keep decoding unchanged. `inputStyle` is the raw
    /// `NumberInputStyle` string (unknown raws resolve to a text field, like
    /// `Question.inputStyle`); the bounds only mean anything alongside it.
    public var inputStyle: String?
    public var defaultAnswer: String?
    public var placeholder: String?
    public var inputMin: Double?
    public var inputMax: Double?
    public var inputStep: Double?
    /// Content-identity fingerprint (plan 42): `CatalogDedupe.promptFingerprint`
    /// of the prompt, written only by `dispatch-mod` (approve/import/backfill).
    /// Optional — pre-plan-42 records lack it until backfilled; readers must
    /// fall back to computing from `prompt`.
    public var promptFingerprint: String?

    public var id: String { recordName }

    public var type: QuestionType? { QuestionType(rawValue: typeRaw) }

    public init(recordName: String, prompt: String, typeRaw: Int, choices: [String],
                credit: String? = nil, approvedAt: Date, tags: [String] = [],
                inputStyle: String? = nil, defaultAnswer: String? = nil,
                placeholder: String? = nil, inputMin: Double? = nil,
                inputMax: Double? = nil, inputStep: Double? = nil,
                promptFingerprint: String? = nil) {
        self.recordName = recordName
        self.prompt = prompt
        self.typeRaw = typeRaw
        self.choices = choices
        self.credit = credit
        self.approvedAt = approvedAt
        self.tags = tags
        self.inputStyle = inputStyle
        self.defaultAnswer = defaultAnswer
        self.placeholder = placeholder
        self.inputMin = inputMin
        self.inputMax = inputMax
        self.inputStep = inputStep
        self.promptFingerprint = promptFingerprint
    }

    /// Field dictionary for record creation — used only by `dispatch-mod`'s
    /// approve path (the app never writes this record type).
    public var fields: [String: CatalogFieldValue] {
        var fields: [String: CatalogFieldValue] = [
            "prompt": .string(prompt),
            "typeRaw": .int(typeRaw),
            "choicesJSON": .string(CatalogChoicesJSON.encode(choices)),
            "approvedAt": .date(approvedAt),
        ]
        if let credit, !credit.isEmpty { fields["credit"] = .string(credit) }
        if !tags.isEmpty { fields["tags"] = .stringList(tags) }
        if let inputStyle, !inputStyle.isEmpty { fields["inputStyle"] = .string(inputStyle) }
        if let defaultAnswer, !defaultAnswer.isEmpty { fields["defaultAnswer"] = .string(defaultAnswer) }
        if let placeholder, !placeholder.isEmpty { fields["placeholder"] = .string(placeholder) }
        if let inputMin { fields["inputMin"] = .double(inputMin) }
        if let inputMax { fields["inputMax"] = .double(inputMax) }
        if let inputStep { fields["inputStep"] = .double(inputStep) }
        if let promptFingerprint, !promptFingerprint.isEmpty {
            fields["promptFingerprint"] = .string(promptFingerprint)
        }
        return fields
    }

    public init?(recordName: String, fields: [String: CatalogFieldValue]) {
        guard let prompt = fields["prompt"]?.stringValue,
              let typeRaw = fields["typeRaw"]?.intValue,
              let approvedAt = fields["approvedAt"]?.dateValue else { return nil }
        self.init(
            recordName: recordName,
            prompt: prompt,
            typeRaw: typeRaw,
            choices: CatalogChoicesJSON.decode(fields["choicesJSON"]?.stringValue ?? "[]"),
            credit: fields["credit"]?.stringValue,
            approvedAt: approvedAt,
            tags: fields["tags"]?.stringListValue ?? [],
            inputStyle: fields["inputStyle"]?.stringValue,
            defaultAnswer: fields["defaultAnswer"]?.stringValue,
            placeholder: fields["placeholder"]?.stringValue,
            inputMin: fields["inputMin"]?.doubleValue,
            inputMax: fields["inputMax"]?.doubleValue,
            inputStep: fields["inputStep"]?.doubleValue,
            promptFingerprint: fields["promptFingerprint"]?.stringValue
        )
    }
}

/// A user submission awaiting moderation. Any authenticated user creates
/// these; they are NOT world-readable once Console permissions are locked in.
/// Anonymous by default — `creditName` is the only optional attribution and
/// no user identifiers are stored beyond CloudKit's own creator metadata.
public struct SubmittedQuestion: Equatable, Sendable, Identifiable {
    public var recordName: String
    public var prompt: String
    public var typeRaw: Int
    public var choices: [String]
    public var creditName: String?
    public var submittedAt: Date
    /// Input configuration (plan 41) — see the `CatalogQuestion` doc comment.
    public var inputStyle: String?
    public var defaultAnswer: String?
    public var placeholder: String?
    public var inputMin: Double?
    public var inputMax: Double?
    public var inputStep: Double?
    /// CloudKit's creator metadata (`created.userRecordName`), populated ONLY
    /// by `dispatch-mod`'s queries for flood detection (plan 38). The app
    /// never reads, stores, or displays it — it is metadata the server
    /// attaches to every record, not a field we write (`fields` excludes it
    /// by construction, and the fields-based init always leaves it nil).
    public var createdUserRecordName: String?

    public var id: String { recordName }

    public var type: QuestionType? { QuestionType(rawValue: typeRaw) }

    public init(recordName: String, prompt: String, typeRaw: Int, choices: [String],
                creditName: String? = nil, submittedAt: Date,
                inputStyle: String? = nil, defaultAnswer: String? = nil,
                placeholder: String? = nil, inputMin: Double? = nil,
                inputMax: Double? = nil, inputStep: Double? = nil,
                createdUserRecordName: String? = nil) {
        self.recordName = recordName
        self.prompt = prompt
        self.typeRaw = typeRaw
        self.choices = choices
        self.creditName = creditName
        self.submittedAt = submittedAt
        self.inputStyle = inputStyle
        self.defaultAnswer = defaultAnswer
        self.placeholder = placeholder
        self.inputMin = inputMin
        self.inputMax = inputMax
        self.inputStep = inputStep
        self.createdUserRecordName = createdUserRecordName
    }

    public var fields: [String: CatalogFieldValue] {
        var fields: [String: CatalogFieldValue] = [
            "prompt": .string(prompt),
            "typeRaw": .int(typeRaw),
            "choicesJSON": .string(CatalogChoicesJSON.encode(choices)),
            "submittedAt": .date(submittedAt),
        ]
        if let creditName, !creditName.isEmpty { fields["creditName"] = .string(creditName) }
        if let inputStyle, !inputStyle.isEmpty { fields["inputStyle"] = .string(inputStyle) }
        if let defaultAnswer, !defaultAnswer.isEmpty { fields["defaultAnswer"] = .string(defaultAnswer) }
        if let placeholder, !placeholder.isEmpty { fields["placeholder"] = .string(placeholder) }
        if let inputMin { fields["inputMin"] = .double(inputMin) }
        if let inputMax { fields["inputMax"] = .double(inputMax) }
        if let inputStep { fields["inputStep"] = .double(inputStep) }
        return fields
    }

    public init?(recordName: String, fields: [String: CatalogFieldValue]) {
        guard let prompt = fields["prompt"]?.stringValue,
              let typeRaw = fields["typeRaw"]?.intValue,
              let submittedAt = fields["submittedAt"]?.dateValue else { return nil }
        self.init(
            recordName: recordName,
            prompt: prompt,
            typeRaw: typeRaw,
            choices: CatalogChoicesJSON.decode(fields["choicesJSON"]?.stringValue ?? "[]"),
            creditName: fields["creditName"]?.stringValue,
            submittedAt: submittedAt,
            inputStyle: fields["inputStyle"]?.stringValue,
            defaultAnswer: fields["defaultAnswer"]?.stringValue,
            placeholder: fields["placeholder"]?.stringValue,
            inputMin: fields["inputMin"]?.doubleValue,
            inputMax: fields["inputMax"]?.doubleValue,
            inputStep: fields["inputStep"]?.doubleValue
        )
    }

    /// Approval = copying this submission into the catalog with a fresh
    /// record name. Only `dispatch-mod` calls this. Stamps the plan-42
    /// content-identity fingerprint (recomputed from the prompt — never
    /// trusted from the client).
    public func approved(recordName: String, approvedAt: Date, tags: [String] = []) -> CatalogQuestion {
        CatalogQuestion(
            recordName: recordName, prompt: prompt, typeRaw: typeRaw, choices: choices,
            credit: creditName, approvedAt: approvedAt, tags: tags,
            inputStyle: inputStyle, defaultAnswer: defaultAnswer, placeholder: placeholder,
            inputMin: inputMin, inputMax: inputMax, inputStep: inputStep,
            promptFingerprint: CatalogDedupe.promptFingerprint(prompt)
        )
    }
}

/// A user-filed flag against a catalog entry. Authenticated users create;
/// not world-readable.
public struct QuestionFlag: Equatable, Sendable, Identifiable {
    public var recordName: String
    public var catalogRecordName: String
    public var reason: String
    public var flaggedAt: Date

    public var id: String { recordName }

    public init(recordName: String, catalogRecordName: String, reason: String, flaggedAt: Date) {
        self.recordName = recordName
        self.catalogRecordName = catalogRecordName
        self.reason = reason
        self.flaggedAt = flaggedAt
    }

    public var fields: [String: CatalogFieldValue] {
        [
            "catalogRecordName": .string(catalogRecordName),
            "reason": .string(reason),
            "flaggedAt": .date(flaggedAt),
        ]
    }

    public init?(recordName: String, fields: [String: CatalogFieldValue]) {
        guard let catalogRecordName = fields["catalogRecordName"]?.stringValue,
              let reason = fields["reason"]?.stringValue,
              let flaggedAt = fields["flaggedAt"]?.dateValue else { return nil }
        self.init(recordName: recordName, catalogRecordName: catalogRecordName,
                  reason: reason, flaggedAt: flaggedAt)
    }
}
