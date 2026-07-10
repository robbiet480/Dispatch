import Foundation

/// Seed-file support for bulk catalog imports (`dispatch-mod import`). A seed
/// file is a curated JSON document of questions headed straight for the
/// public catalog — the same moderation boundary applies: parsing lives here
/// so it is unit-testable, but only `dispatch-mod` turns drafts into records.
///
/// File shape:
/// ```json
/// {
///   "source": "where the set came from (documentation only)",
///   "defaultCredit": "credit applied to entries without their own",
///   "questions": [
///     {"prompt": "…", "type": "yesNo", "choices": ["…"], "credit": "…", "tags": ["…"]}
///   ]
/// }
/// ```
/// `type` is the `QuestionType` case name (`tokens`, `multipleChoice`,
/// `yesNo`, `location`, `people`, `number`, `note`). `choices` is only valid
/// for `multipleChoice`; `credit` and `tags` are optional.
public struct CatalogSeedEntry: Decodable, Equatable, Sendable {
    public var prompt: String
    public var type: String
    public var choices: [String]
    public var credit: String?
    public var tags: [String]

    enum CodingKeys: String, CodingKey {
        case prompt, type, choices, credit, tags
    }

    public init(prompt: String, type: String, choices: [String] = [],
                credit: String? = nil, tags: [String] = []) {
        self.prompt = prompt
        self.type = type
        self.choices = choices
        self.credit = credit
        self.tags = tags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decode(String.self, forKey: .prompt)
        type = try container.decode(String.self, forKey: .type)
        choices = try container.decodeIfPresent([String].self, forKey: .choices) ?? []
        credit = try container.decodeIfPresent(String.self, forKey: .credit)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

/// A parsed, structurally-valid question ready for record creation. Only
/// `dispatch-mod` assigns the record name and approval timestamp.
public struct CatalogSeedDraft: Equatable, Sendable {
    public var prompt: String
    public var typeRaw: Int
    public var choices: [String]
    public var credit: String?
    public var tags: [String]

    public func catalogQuestion(recordName: String, approvedAt: Date) -> CatalogQuestion {
        CatalogQuestion(
            recordName: recordName, prompt: prompt, typeRaw: typeRaw,
            choices: choices, credit: credit, approvedAt: approvedAt, tags: tags
        )
    }
}

public enum CatalogSeedError: Error, Equatable, CustomStringConvertible {
    /// Every problem in the file, one line per entry, so a bad seed file is
    /// fixed in one round trip rather than error-by-error.
    case problems([String])

    public var description: String {
        switch self {
        case .problems(let problems):
            "seed file has \(problems.count) problem(s):\n"
                + problems.map { "  - \($0)" }.joined(separator: "\n")
        }
    }
}

public enum CatalogSeed {
    struct File: Decodable {
        var defaultCredit: String?
        var questions: [CatalogSeedEntry]
    }

    /// `QuestionType` from its case name. Kept explicit (no reflection) so a
    /// renamed case is a compile-time reminder to keep seed files working.
    public static func questionType(named name: String) -> QuestionType? {
        switch name {
        case "tokens": .tokens
        case "multipleChoice": .multipleChoice
        case "yesNo": .yesNo
        case "location": .location
        case "people": .people
        case "number": .number
        case "note": .note
        default: nil
        }
    }

    /// Decode and structurally validate a whole seed file. Collects every
    /// problem (unknown type, `CatalogValidation` failures, duplicate prompts
    /// within the file) before throwing; returns normalized drafts in file
    /// order on success.
    public static func parse(_ data: Data) throws -> [CatalogSeedDraft] {
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw CatalogSeedError.problems(["not a valid seed file: \(error)"])
        }

        var problems: [String] = []
        var drafts: [CatalogSeedDraft] = []
        var seenPrompts = Set<String>()

        for (index, entry) in file.questions.enumerated() {
            let label = "questions[\(index)] \"\(entry.prompt)\""
            guard let type = questionType(named: entry.type) else {
                problems.append("\(label): unknown type \"\(entry.type)\"")
                continue
            }
            let credit = entry.credit ?? file.defaultCredit
            let errors = CatalogValidation.validate(
                prompt: entry.prompt, typeRaw: type.rawValue,
                choices: entry.choices, creditName: credit
            )
            guard errors.isEmpty else {
                problems.append("\(label): " + errors.map(\.message).joined(separator: " "))
                continue
            }
            let normalized = CatalogValidation.normalized(
                prompt: entry.prompt, choices: entry.choices, creditName: credit
            )
            if !seenPrompts.insert(normalized.prompt.lowercased()).inserted {
                problems.append("\(label): duplicate prompt within the file")
                continue
            }
            drafts.append(CatalogSeedDraft(
                prompt: normalized.prompt, typeRaw: type.rawValue,
                choices: normalized.choices, credit: normalized.creditName,
                tags: entry.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            ))
        }

        guard problems.isEmpty else { throw CatalogSeedError.problems(problems) }
        return drafts
    }
}
