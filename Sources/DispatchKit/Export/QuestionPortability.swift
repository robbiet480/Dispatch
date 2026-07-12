import Foundation

/// Moving question DEFINITIONS in and out of Dispatch as CSV/JSON (plan 47,
/// issue #57) — distinct from the report-DATA exporters (`CSVExporter`,
/// `V2Exporter`, `DayOneExporter`, `MarkdownExporter`), which export the
/// answers you've filed. This exports the QUESTIONS themselves: prompt, type,
/// choices, input configuration, report kinds, enabled, sort order — so you
/// can back them up, edit them elsewhere, or reproduce a curated set on a
/// clean install.
///
/// Pure and platform-neutral: value types + pure functions, no I/O, no
/// SwiftData, no CloudKit. The Mac UI does the file picking and the SwiftData
/// commit; everything decision-shaped (parse, validate, dedupe, preview) lives
/// here and is unit-tested.

/// A single question's exportable definition. Round-trips a `Question` losslessly
/// (identity — `uniqueIdentifier` — is intentionally NOT carried; imports mint
/// fresh identities so a re-import never collides with sync).
public struct QuestionDefinition: Equatable, Sendable, Codable {
    public var prompt: String
    public var typeRaw: Int
    public var choices: [String]
    public var reportKindsRaw: [String]
    public var isEnabled: Bool
    public var sortOrder: Int
    public var placeholder: String?
    public var inputStyleRaw: String?
    public var defaultAnswer: String?
    public var inputMin: Double?
    public var inputMax: Double?
    public var inputStep: Double?
    public var visualizationRaw: String?
    public var stateOfMindKind: String?
    public var allowsMultipleSelection: Bool?

    public init(prompt: String, typeRaw: Int, choices: [String] = [],
                reportKindsRaw: [String] = [ReportKind.regular.rawValue],
                isEnabled: Bool = true, sortOrder: Int = 0,
                placeholder: String? = nil, inputStyleRaw: String? = nil,
                defaultAnswer: String? = nil, inputMin: Double? = nil,
                inputMax: Double? = nil, inputStep: Double? = nil,
                visualizationRaw: String? = nil, stateOfMindKind: String? = nil,
                allowsMultipleSelection: Bool? = nil) {
        self.prompt = prompt
        self.typeRaw = typeRaw
        self.choices = choices
        self.reportKindsRaw = reportKindsRaw
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.placeholder = placeholder
        self.inputStyleRaw = inputStyleRaw
        self.defaultAnswer = defaultAnswer
        self.inputMin = inputMin
        self.inputMax = inputMax
        self.inputStep = inputStep
        self.visualizationRaw = visualizationRaw
        self.stateOfMindKind = stateOfMindKind
        self.allowsMultipleSelection = allowsMultipleSelection
    }

    public var type: QuestionType? { QuestionType(rawValue: typeRaw) }

    // JSON uses the `QuestionType` case NAME for `type` (matching the catalog
    // seed shape), report kinds as their raw-value strings, and the plan-41
    // input-config keys — so a curated catalog seed file and a personal export
    // are the same shape (extra personal fields default when a seed is
    // imported; catalog-only fields like credit/tags are ignored on import).
    enum CodingKeys: String, CodingKey {
        case prompt, type, choices, reportKinds, enabled, sortOrder, placeholder
        case inputStyle, defaultAnswer, inputMin, inputMax, inputStep
        case visualization, stateOfMindKind, allowsMultipleSelection
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decode(String.self, forKey: .prompt)
        let typeName = try c.decode(String.self, forKey: .type)
        guard let type = QuestionPortability.questionType(named: typeName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown question type \"\(typeName)\"")
        }
        typeRaw = type.rawValue
        choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
        reportKindsRaw = try c.decodeIfPresent([String].self, forKey: .reportKinds)
            ?? [ReportKind.regular.rawValue]
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        inputStyleRaw = try c.decodeIfPresent(String.self, forKey: .inputStyle)
        defaultAnswer = try c.decodeIfPresent(String.self, forKey: .defaultAnswer)
        inputMin = try c.decodeIfPresent(Double.self, forKey: .inputMin)
        inputMax = try c.decodeIfPresent(Double.self, forKey: .inputMax)
        inputStep = try c.decodeIfPresent(Double.self, forKey: .inputStep)
        visualizationRaw = try c.decodeIfPresent(String.self, forKey: .visualization)
        stateOfMindKind = try c.decodeIfPresent(String.self, forKey: .stateOfMindKind)
        allowsMultipleSelection = try c.decodeIfPresent(Bool.self, forKey: .allowsMultipleSelection)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(QuestionPortability.caseName(for: type ?? .tokens), forKey: .type)
        try c.encode(choices, forKey: .choices)
        try c.encode(reportKindsRaw, forKey: .reportKinds)
        try c.encode(isEnabled, forKey: .enabled)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encodeIfPresent(placeholder, forKey: .placeholder)
        try c.encodeIfPresent(inputStyleRaw, forKey: .inputStyle)
        try c.encodeIfPresent(defaultAnswer, forKey: .defaultAnswer)
        try c.encodeIfPresent(inputMin, forKey: .inputMin)
        try c.encodeIfPresent(inputMax, forKey: .inputMax)
        try c.encodeIfPresent(inputStep, forKey: .inputStep)
        try c.encodeIfPresent(visualizationRaw, forKey: .visualization)
        try c.encodeIfPresent(stateOfMindKind, forKey: .stateOfMindKind)
        try c.encodeIfPresent(allowsMultipleSelection, forKey: .allowsMultipleSelection)
    }
}

public enum QuestionPortabilityError: Error, Equatable, CustomStringConvertible {
    case malformedJSON(String)
    case malformedCSV(String)

    public var description: String {
        switch self {
        case .malformedJSON(let detail): "Not a valid question JSON file: \(detail)"
        case .malformedCSV(let detail): "Not a valid question CSV file: \(detail)"
        }
    }
}

public enum QuestionPortability {
    /// Top-level JSON wrapper. `questions` mirrors the catalog seed's key so a
    /// seed file decodes here too (its `source`/`defaultCredit` keys are
    /// ignored, its per-entry `credit`/`tags` ignored per-row).
    struct File: Codable { var questions: [QuestionDefinition] }

    // MARK: - Type <-> case-name (complete, includes plan-28 `.time`)

    static func questionType(named name: String) -> QuestionType? {
        switch name {
        case "tokens": .tokens
        case "multipleChoice": .multipleChoice
        case "yesNo": .yesNo
        case "location": .location
        case "people": .people
        case "number": .number
        case "note": .note
        case "time": .time
        default: nil
        }
    }

    static func caseName(for type: QuestionType) -> String {
        switch type {
        case .tokens: "tokens"
        case .multipleChoice: "multipleChoice"
        case .yesNo: "yesNo"
        case .location: "location"
        case .people: "people"
        case .number: "number"
        case .note: "note"
        case .time: "time"
        }
    }

    // MARK: - JSON

    public static func encodeJSON(_ definitions: [QuestionDefinition]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(questions: definitions))
    }

    public static func decodeJSON(_ data: Data) throws -> [QuestionDefinition] {
        do {
            return try JSONDecoder().decode(File.self, from: data).questions
        } catch {
            // Tolerate a bare top-level array of definitions too.
            if let bare = try? JSONDecoder().decode([QuestionDefinition].self, from: data) {
                return bare
            }
            throw QuestionPortabilityError.malformedJSON("\(error)")
        }
    }

    // MARK: - CSV (RFC-4180)

    /// Documented column schema (issue #57). Choices and report kinds are
    /// JSON arrays inside their cell so user text with commas/quotes survives;
    /// booleans are `true`/`false`; empty numeric/text cells mean nil.
    static let csvColumns = [
        "prompt", "type", "choices", "reportKinds", "enabled", "sortOrder",
        "placeholder", "inputStyle", "defaultAnswer", "inputMin", "inputMax",
        "inputStep", "visualization", "stateOfMindKind", "allowsMultipleSelection",
    ]

    public static func encodeCSV(_ definitions: [QuestionDefinition]) -> String {
        var rows = [csvColumns.map(csvField).joined(separator: ",")]
        for def in definitions {
            let cells: [String] = [
                def.prompt,
                caseName(for: def.type ?? .tokens),
                jsonArrayCell(def.choices),
                jsonArrayCell(def.reportKindsRaw),
                def.isEnabled ? "true" : "false",
                String(def.sortOrder),
                def.placeholder ?? "",
                def.inputStyleRaw ?? "",
                def.defaultAnswer ?? "",
                numberCell(def.inputMin),
                numberCell(def.inputMax),
                numberCell(def.inputStep),
                def.visualizationRaw ?? "",
                def.stateOfMindKind ?? "",
                def.allowsMultipleSelection.map { $0 ? "true" : "false" } ?? "",
            ]
            rows.append(cells.map(csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    public static func decodeCSV(_ text: String) throws -> [QuestionDefinition] {
        let records = parseCSV(text)
        guard let header = records.first else {
            throw QuestionPortabilityError.malformedCSV("empty file")
        }
        // Build the column index manually (first occurrence wins) rather than
        // Dictionary(uniqueKeysWithValues:), which traps at runtime on a
        // duplicate header column — and the header is user-provided input.
        var index: [String: Int] = [:]
        for (position, name) in header.enumerated() where index[name] == nil {
            index[name] = position
        }
        guard index["prompt"] != nil, index["type"] != nil else {
            throw QuestionPortabilityError.malformedCSV("missing required 'prompt'/'type' columns")
        }
        func cell(_ row: [String], _ column: String) -> String {
            guard let position = index[column], position < row.count else { return "" }
            return row[position]
        }
        var definitions: [QuestionDefinition] = []
        for (offset, row) in records.dropFirst().enumerated() {
            // Skip blank trailing lines (a single empty field).
            if row.count == 1, row[0].isEmpty { continue }
            let typeName = cell(row, "type")
            guard let type = questionType(named: typeName) else {
                throw QuestionPortabilityError.malformedCSV(
                    "row \(offset + 2): unknown question type \"\(typeName)\"")
            }
            let enabled = cell(row, "enabled").lowercased()
            let ams = cell(row, "allowsMultipleSelection").lowercased()
            definitions.append(QuestionDefinition(
                prompt: cell(row, "prompt"),
                typeRaw: type.rawValue,
                choices: decodeJSONArrayCell(cell(row, "choices")),
                reportKindsRaw: {
                    let decoded = decodeJSONArrayCell(cell(row, "reportKinds"))
                    return decoded.isEmpty ? [ReportKind.regular.rawValue] : decoded
                }(),
                isEnabled: enabled.isEmpty ? true : (enabled == "true"),
                sortOrder: Int(cell(row, "sortOrder")) ?? 0,
                placeholder: nilIfEmpty(cell(row, "placeholder")),
                inputStyleRaw: nilIfEmpty(cell(row, "inputStyle")),
                defaultAnswer: nilIfEmpty(cell(row, "defaultAnswer")),
                inputMin: Double(cell(row, "inputMin")),
                inputMax: Double(cell(row, "inputMax")),
                inputStep: Double(cell(row, "inputStep")),
                visualizationRaw: nilIfEmpty(cell(row, "visualization")),
                stateOfMindKind: nilIfEmpty(cell(row, "stateOfMindKind")),
                allowsMultipleSelection: ams.isEmpty ? nil : (ams == "true")
            ))
        }
        return definitions
    }

    // MARK: - CSV helpers

    private static func nilIfEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func numberCell(_ value: Double?) -> String {
        guard let value else { return "" }
        if value.truncatingRemainder(dividingBy: 1) == 0, value.magnitude < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }

    private static func jsonArrayCell(_ array: [String]) -> String {
        guard !array.isEmpty else { return "" }
        guard let data = try? JSONEncoder().encode(array),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    private static func decodeJSONArrayCell(_ cell: String) -> [String] {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return array
    }

    /// RFC-4180 field quoting: wrap in double quotes and double any embedded
    /// quote when the field contains a comma, quote, CR, or LF.
    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// RFC-4180 parser: rows of fields, honoring quoted fields with embedded
    /// commas, quotes (doubled), and newlines. Normalizes CRLF to LF.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        let scalars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        var i = 0
        while i < scalars.count {
            let ch = scalars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\""); i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.append(ch)
                }
            }
            i += 1
        }
        // Flush the final field/row (no trailing newline).
        row.append(field)
        rows.append(row)
        return rows
    }
}

// MARK: - SwiftData bridge

public extension QuestionDefinition {
    /// Snapshot an existing `Question` into a portable definition.
    init(_ question: Question) {
        self.init(
            prompt: question.prompt,
            typeRaw: question.typeRaw,
            choices: question.choices,
            reportKindsRaw: question.reportKindsRaw,
            isEnabled: question.isEnabled,
            sortOrder: question.sortOrder,
            placeholder: question.placeholderString,
            inputStyleRaw: question.inputStyleRaw,
            defaultAnswer: question.defaultAnswerString,
            inputMin: question.inputMin,
            inputMax: question.inputMax,
            inputStep: question.inputStep,
            visualizationRaw: question.visualizationRaw,
            stateOfMindKind: question.stateOfMindKind,
            allowsMultipleSelection: question.allowsMultipleSelectionRaw
        )
    }

    /// A fresh (un-inserted) `Question` from this definition, placed at
    /// `sortOrder`. Identity is a new UUID — imports never collide with sync.
    func makeQuestion(sortOrder: Int) -> Question {
        let question = Question()
        question.prompt = prompt
        question.typeRaw = typeRaw
        question.choices = choices
        question.reportKindsRaw = reportKindsRaw
        question.isEnabled = isEnabled
        question.sortOrder = sortOrder
        question.placeholderString = placeholder
        question.inputStyleRaw = inputStyleRaw
        question.defaultAnswerString = defaultAnswer
        question.inputMin = inputMin
        question.inputMax = inputMax
        question.inputStep = inputStep
        question.visualizationRaw = visualizationRaw
        question.stateOfMindKind = stateOfMindKind
        question.allowsMultipleSelectionRaw = allowsMultipleSelection
        return question
    }
}

// MARK: - Import plan (preview before commit)

/// Why an incoming row won't be added.
public enum QuestionImportSkipReason: Equatable, Sendable {
    /// Prompt normalizes to a question already in the store.
    case duplicateOfExisting
    /// Prompt normalizes to an earlier row in the same import.
    case duplicateWithinImport
}

public struct QuestionImportSkip: Equatable, Sendable {
    public var index: Int
    public var prompt: String
    public var reason: QuestionImportSkipReason
}

public struct QuestionImportRowError: Equatable, Sendable {
    public var index: Int
    public var prompt: String
    public var errors: [CatalogValidationError]
}

/// A previewable import (the `--dry-run`-style sheet issue #57 asks for):
/// which rows would be added, skipped as duplicates, or rejected as invalid.
/// Pure — computed from the parsed definitions and the existing prompts, with
/// no mutation. The caller commits `adds` to SwiftData.
public struct QuestionImportPlan: Equatable, Sendable {
    public var adds: [QuestionDefinition]
    public var skips: [QuestionImportSkip]
    public var errors: [QuestionImportRowError]

    public var addCount: Int { adds.count }
    public var skipCount: Int { skips.count }
    public var errorCount: Int { errors.count }

    /// Dedupe uses `CatalogDedupe.normalizedPrompt` — the same identity the
    /// catalog uses — against `existingPrompts` and earlier rows in the import.
    /// Validation reuses `CatalogValidation` (issue #57: "reuse kit
    /// CatalogValidation where it fits"). Order is preserved.
    public static func make(incoming: [QuestionDefinition],
                            existingPrompts: [String]) -> QuestionImportPlan {
        var adds: [QuestionDefinition] = []
        var skips: [QuestionImportSkip] = []
        var errors: [QuestionImportRowError] = []
        let seen = Set(existingPrompts
            .map(CatalogDedupe.normalizedPrompt)
            .filter { !$0.isEmpty })
        var seenWithinImport = Set<String>()

        for (index, def) in incoming.enumerated() {
            let validationErrors = CatalogValidation.validate(
                prompt: def.prompt, typeRaw: def.typeRaw,
                choices: def.choices,
                inputStyle: def.inputStyleRaw, defaultAnswer: def.defaultAnswer,
                placeholder: def.placeholder
            )
            guard validationErrors.isEmpty else {
                errors.append(QuestionImportRowError(
                    index: index, prompt: def.prompt, errors: validationErrors))
                continue
            }
            let normalized = CatalogDedupe.normalizedPrompt(def.prompt)
            if seen.contains(normalized) {
                skips.append(QuestionImportSkip(
                    index: index, prompt: def.prompt, reason: .duplicateOfExisting))
            } else if seenWithinImport.contains(normalized) {
                skips.append(QuestionImportSkip(
                    index: index, prompt: def.prompt, reason: .duplicateWithinImport))
            } else {
                seenWithinImport.insert(normalized)
                adds.append(def)
            }
        }
        return QuestionImportPlan(adds: adds, skips: skips, errors: errors)
    }
}
