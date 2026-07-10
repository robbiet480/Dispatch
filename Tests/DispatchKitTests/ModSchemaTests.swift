import XCTest

/// Guards the repo-canonical CloudKit schema (Sources/dispatch-mod/schema.ckdb)
/// against drifting from the documented truth in docs/moderation.md:
/// the permission matrix (§3a), the index list including the
/// createdUserRecordName/___createdBy trap (§3b), and the moderator
/// security role (bottom section). If `dispatch-mod setup --export`
/// re-snapshots the file from a live environment, these assertions verify
/// the battle-tested invariants survived the round trip.
final class ModSchemaTests: XCTestCase {
    static let schema: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DispatchKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/dispatch-mod/schema.ckdb")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// Whitespace-normalized schema (runs of spaces/newlines collapsed to one
    /// space) so assertions don't depend on the exact column alignment of
    /// schema.ckdb — a `setup --export` re-snapshot may realign it.
    static let normalizedSchema: String = normalize(schema)

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }

    /// The whitespace-normalized body of one RECORD TYPE block.
    private func block(_ type: String) -> String {
        let schema = Self.normalizedSchema
        guard let start = schema.range(of: "RECORD TYPE \(type) ("),
              let end = schema.range(of: ");", range: start.upperBound..<schema.endIndex)
        else { return "" }
        return String(schema[start.upperBound..<end.lowerBound])
    }

    func testSchemaFileExistsAndDefinesAllRecordTypes() {
        XCTAssertTrue(Self.schema.hasPrefix("DEFINE SCHEMA"))
        for type in ["CatalogQuestion", "SubmittedQuestion", "QuestionFlag"] {
            XCTAssertFalse(block(type).isEmpty, "missing RECORD TYPE \(type)")
        }
    }

    func testModeratorRoleIsDefinedAndGranted() {
        XCTAssertTrue(Self.normalizedSchema.contains("CREATE ROLE moderator;"))
        // Server key executes as a regular user: it needs explicit grants.
        XCTAssertTrue(block("CatalogQuestion").contains("GRANT CREATE, WRITE TO moderator"))
        XCTAssertTrue(block("SubmittedQuestion").contains("GRANT READ, WRITE TO moderator"))
        XCTAssertTrue(block("QuestionFlag").contains("GRANT READ, WRITE TO moderator"))
    }

    func testCatalogQuestionIsWorldReadableButNotClientWritable() {
        let catalog = block("CatalogQuestion")
        XCTAssertTrue(catalog.contains("GRANT READ TO \"_world\""))
        // The moderation boundary: no client-side create/write path.
        XCTAssertFalse(catalog.contains("CREATE TO \"_icloud\""))
        XCTAssertFalse(catalog.contains("CREATE TO \"_world\""))
        XCTAssertFalse(catalog.contains("WRITE TO \"_icloud\""))
        XCTAssertFalse(catalog.contains("WRITE TO \"_world\""))
        XCTAssertFalse(catalog.contains("TO \"_creator\""))
    }

    func testSubmissionAndFlagPermissionMatrix() {
        let submission = block("SubmittedQuestion")
        XCTAssertTrue(submission.contains("GRANT READ, WRITE TO \"_creator\""))
        XCTAssertTrue(submission.contains("GRANT CREATE TO \"_icloud\""))
        XCTAssertFalse(submission.contains("READ TO \"_world\""), "queue must not be world-readable")

        let flag = block("QuestionFlag")
        XCTAssertTrue(flag.contains("GRANT READ TO \"_creator\""))
        XCTAssertFalse(flag.contains("READ, WRITE TO \"_creator\""), "flags are creator-read-only")
        XCTAssertTrue(flag.contains("GRANT CREATE TO \"_icloud\""))
        XCTAssertFalse(flag.contains("READ TO \"_world\""))
    }

    func testDocumentedIndexes() {
        // recordName queryable everywhere the app/tool queries.
        for type in ["CatalogQuestion", "SubmittedQuestion", "QuestionFlag"] {
            XCTAssertTrue(
                block(type).contains("\"___recordID\" REFERENCE QUERYABLE"),
                "\(type) needs a queryable recordName index")
        }
        // Sort indexes.
        XCTAssertTrue(block("CatalogQuestion").contains("approvedAt TIMESTAMP SORTABLE"))
        XCTAssertTrue(block("SubmittedQuestion").contains("submittedAt TIMESTAMP SORTABLE"))
        XCTAssertTrue(block("QuestionFlag").contains("flaggedAt TIMESTAMP SORTABLE"))
    }

    func testCreatedByQueryableTrap() {
        // Creator-scoped read permissions make CloudKit inject an implicit
        // creator filter, which requires the creator metadata field to be
        // queryable. Console calls it createdUserRecordName, server errors
        // say createdBy, and the schema language spells it ___createdBy.
        XCTAssertTrue(block("SubmittedQuestion").contains("\"___createdBy\" REFERENCE QUERYABLE"))
        XCTAssertTrue(block("QuestionFlag").contains("\"___createdBy\" REFERENCE QUERYABLE"))
        // CatalogQuestion keeps world read — no creator filter, no index needed.
        XCTAssertFalse(block("CatalogQuestion").contains("\"___createdBy\" REFERENCE QUERYABLE"))
    }

    func testNoSearchableIndexes() {
        // App search is client-side over loaded entries (docs §3b).
        XCTAssertFalse(Self.schema.contains("SEARCHABLE"))
    }
}
