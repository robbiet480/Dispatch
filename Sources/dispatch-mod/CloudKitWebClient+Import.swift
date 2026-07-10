#if os(macOS)
import DispatchKit
import Foundation

/// Bulk-import support for `dispatch-mod import` (curated seed files, e.g.
/// docs/catalog/reporter-tumblr-seed.json). Same moderation boundary as
/// approve: this executable is the only writer of `CatalogQuestion` records.
extension CloudKitWebClient {
    func catalogQuestions() throws -> [CatalogQuestion] {
        try queryRecords(recordType: CatalogRecordType.catalogQuestion, sortField: "approvedAt")
            .compactMap { CatalogQuestion(recordName: $0.0, fields: $0.1) }
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
}
#endif
