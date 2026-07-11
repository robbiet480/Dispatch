#if os(macOS)
import DispatchKit
import Foundation

/// Bulk-import support for `dispatch-mod import` (curated seed files, e.g.
/// docs/catalog/reporter-tumblr-seed.json). Same moderation boundary as
/// approve: this executable is the only writer of `CatalogQuestion` records.
extension CloudKitWebClient {
    func catalogQuestions() throws -> [CatalogQuestion] {
        try queryRecords(recordType: CatalogRecordType.catalogQuestion, sortField: "approvedAt")
            .compactMap { CatalogQuestion(recordName: $0.recordName, fields: $0.fields) }
    }

    /// Batch-create catalog entries. `records/modify` caps at 200 operations
    /// per request, so the list is chunked; `onCreate` fires per record after
    /// its chunk succeeds. On a mid-import failure earlier chunks stay
    /// written — re-running import is safe because the caller skips prompts
    /// already in the catalog.
    func createCatalogQuestions(
        _ questions: [CatalogQuestion], onCreate: (CatalogQuestion) -> Void = { _ in }
    ) throws {
        for start in stride(from: 0, to: questions.count, by: 200) {
            let chunk = Array(questions[start..<min(start + 200, questions.count)])
            let response = try post(operation: "records/modify", body: [
                "operations": chunk.map { question in
                    [
                        "operationType": "create",
                        "record": [
                            "recordType": CatalogRecordType.catalogQuestion,
                            "recordName": question.recordName,
                            "fields": Self.fieldJSON(question.fields),
                        ] as [String: Any],
                    ] as [String: Any]
                },
            ])
            // A 200 response can still carry per-record errors.
            let failures = (response["records"] as? [[String: Any]] ?? []).compactMap { raw in
                (raw["serverErrorCode"] as? String).map { code in
                    "\(raw["recordName"] as? String ?? "?"): \(code) \(raw["reason"] as? String ?? "")"
                }
            }
            guard failures.isEmpty else {
                throw ClientError.server(
                    code: "BATCH_CREATE_FAILED",
                    reason: failures.joined(separator: "; ")
                )
            }
            chunk.forEach(onCreate)
        }
    }

    /// Stamp `promptFingerprint` onto catalog entries that lack it (plan 42
    /// backfill for pre-plan-42 records). Safe to re-run: already-stamped
    /// entries are untouched. Uses `forceUpdate` (no etag dance — the tool
    /// is the only writer of this record type) with only the fingerprint
    /// field, and verifies every per-record result.
    func backfillFingerprints(
        onStamp: (CatalogQuestion) -> Void = { _ in }
    ) throws -> (stamped: Int, alreadyStamped: Int) {
        let entries = try catalogQuestions()
        let missing = entries.filter { $0.promptFingerprint == nil }
        for entry in missing {
            let response = try post(operation: "records/modify", body: [
                "operations": [[
                    "operationType": "forceUpdate",
                    "record": [
                        "recordType": CatalogRecordType.catalogQuestion,
                        "recordName": entry.recordName,
                        "fields": Self.fieldJSON([
                            "promptFingerprint": .string(CatalogDedupe.promptFingerprint(entry.prompt)),
                        ]),
                    ] as [String: Any],
                ] as [String: Any]],
            ])
            try Self.verifyModifyResponse(response, recordName: entry.recordName)
            onStamp(entry)
        }
        return (missing.count, entries.count - missing.count)
    }
}
#endif
