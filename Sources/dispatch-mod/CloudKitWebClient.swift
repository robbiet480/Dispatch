#if os(macOS)
import DispatchKit
import Foundation

/// Minimal CloudKit Web Services client for the moderation flows. Requests
/// are signed with the server-to-server key (see CKWebServicesSigner for the
/// verified signature format). This is the ONLY code path anywhere in the
/// project that creates `CatalogQuestion` records — approval is the mod tool
/// copying a submission into the catalog; clients cannot do it by construction.
struct CloudKitWebClient {
    static let baseURL = URL(string: "https://api.apple-cloudkit.com")!

    let signer: CKWebServicesSigner
    let container: String
    let environment: String

    enum ClientError: Error, CustomStringConvertible {
        case http(status: Int, body: String)
        case server(code: String, reason: String)
        case malformedResponse(String)

        var description: String {
            switch self {
            case .http(let status, let body):
                "HTTP \(status): \(body)"
            case .server(let code, let reason):
                "CloudKit error \(code): \(reason)"
            case .malformedResponse(let detail):
                "Malformed CloudKit response: \(detail)"
            }
        }
    }

    // MARK: - Transport

    private func subpath(_ operation: String) -> String {
        "/database/1/\(container)/\(environment)/public/\(operation)"
    }

    /// Synchronous signed POST. The tool is a sequential CLI/localhost
    /// dashboard; blocking keeps it free of Sendable ceremony.
    func post(operation: String, body: [String: Any]) throws -> [String: Any] {
        let path = subpath(operation)
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (header, value) in try signer.headers(body: bodyData, subpath: path) {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result<(Data, Int), Error> = .failure(
            ClientError.malformedResponse("no response")
        )
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                outcome = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                outcome = .success((data ?? Data(), http.statusCode))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()

        let (data, status) = try outcome.get()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let code = json["serverErrorCode"] as? String {
            throw ClientError.server(code: code, reason: json["reason"] as? String ?? "—")
        }
        guard (200..<300).contains(status) else {
            throw ClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return json
    }

    // MARK: - Field JSON ↔ kit values

    /// Write-side field JSON. Types are explicit so the server can't
    /// mis-infer (a bare epoch-ms integer would otherwise create INT64,
    /// not TIMESTAMP).
    static func fieldJSON(_ fields: [String: CatalogFieldValue]) -> [String: Any] {
        fields.mapValues { value in
            switch value {
            case .string(let string): ["value": string, "type": "STRING"]
            case .int(let int): ["value": int, "type": "INT64"]
            case .date(let date): ["value": Int(date.timeIntervalSince1970 * 1000), "type": "TIMESTAMP"]
            case .stringList(let list): ["value": list, "type": "STRING_LIST"]
            }
        }
    }

    static func fieldValues(_ json: [String: Any]) -> [String: CatalogFieldValue] {
        var fields: [String: CatalogFieldValue] = [:]
        for (name, raw) in json {
            guard let entry = raw as? [String: Any] else { continue }
            let type = entry["type"] as? String ?? ""
            switch type {
            case "TIMESTAMP":
                if let ms = entry["value"] as? Double {
                    fields[name] = .date(Date(timeIntervalSince1970: ms / 1000))
                }
            case "STRING_LIST":
                if let list = entry["value"] as? [String] { fields[name] = .stringList(list) }
            case "INT64":
                if let int = entry["value"] as? Int { fields[name] = .int(int) }
            default:
                if let string = entry["value"] as? String { fields[name] = .string(string) }
                else if let int = entry["value"] as? Int { fields[name] = .int(int) }
            }
        }
        return fields
    }

    func queryRecords(recordType: String, sortField: String) throws -> [(String, [String: CatalogFieldValue])] {
        var records: [(String, [String: CatalogFieldValue])] = []
        var continuationMarker: String?
        repeat {
            var body: [String: Any] = [
                "query": [
                    "recordType": recordType,
                    "sortBy": [["fieldName": sortField, "ascending": false]],
                ] as [String: Any],
                "resultsLimit": 100,
            ]
            if let continuationMarker { body["continuationMarker"] = continuationMarker }
            let response = try post(operation: "records/query", body: body)
            guard let rawRecords = response["records"] as? [[String: Any]] else {
                throw ClientError.malformedResponse("no records array")
            }
            for raw in rawRecords {
                guard let recordName = raw["recordName"] as? String,
                      let fields = raw["fields"] as? [String: Any] else { continue }
                records.append((recordName, Self.fieldValues(fields)))
            }
            continuationMarker = response["continuationMarker"] as? String
        } while continuationMarker != nil
        return records
    }

    // MARK: - Moderation operations

    func pendingSubmissions() throws -> [SubmittedQuestion] {
        try queryRecords(recordType: CatalogRecordType.submittedQuestion, sortField: "submittedAt")
            .compactMap { SubmittedQuestion(recordName: $0.0, fields: $0.1) }
    }

    func flags() throws -> [QuestionFlag] {
        try queryRecords(recordType: CatalogRecordType.questionFlag, sortField: "flaggedAt")
            .compactMap { QuestionFlag(recordName: $0.0, fields: $0.1) }
    }

    func lookupSubmission(recordName: String) throws -> SubmittedQuestion {
        let response = try post(
            operation: "records/lookup",
            body: ["records": [["recordName": recordName]]]
        )
        guard let raw = (response["records"] as? [[String: Any]])?.first else {
            throw ClientError.malformedResponse("lookup returned no record")
        }
        if let code = raw["serverErrorCode"] as? String {
            throw ClientError.server(code: code, reason: raw["reason"] as? String ?? recordName)
        }
        guard let fields = raw["fields"] as? [String: Any],
              let submission = SubmittedQuestion(
                  recordName: recordName, fields: Self.fieldValues(fields)
              ) else {
            throw ClientError.malformedResponse("submission \(recordName) has an unexpected shape")
        }
        return submission
    }

    /// Approve: validate structurally, create the CatalogQuestion (fresh
    /// record name), then delete the submission. Two modify calls so a
    /// delete failure can't lose the approval.
    @discardableResult
    func approve(submissionRecordName: String, tags: [String]) throws -> CatalogQuestion {
        let submission = try lookupSubmission(recordName: submissionRecordName)
        let errors = CatalogValidation.validate(
            prompt: submission.prompt, typeRaw: submission.typeRaw,
            choices: submission.choices, creditName: submission.creditName
        )
        guard errors.isEmpty else {
            throw ClientError.malformedResponse(
                "submission fails validation: " + errors.map(\.message).joined(separator: " ")
            )
        }
        let catalog = submission.approved(
            recordName: UUID().uuidString, approvedAt: Date(), tags: tags
        )
        _ = try post(operation: "records/modify", body: [
            "operations": [[
                "operationType": "create",
                "record": [
                    "recordType": CatalogRecordType.catalogQuestion,
                    "recordName": catalog.recordName,
                    "fields": Self.fieldJSON(catalog.fields),
                ] as [String: Any],
            ] as [String: Any]],
        ])
        do {
            try delete(recordName: submissionRecordName, recordType: CatalogRecordType.submittedQuestion)
        } catch {
            FileHandle.standardError.write(Data("""
            WARNING: catalog entry \(catalog.recordName) was created, but deleting the \
            submission failed (\(error)). Leftover submission: \(submissionRecordName)
            Reject it manually — `dispatch-mod reject \(submissionRecordName)` — do NOT \
            re-approve it (that would duplicate the catalog entry).

            """.utf8))
        }
        return catalog
    }

    func reject(submissionRecordName: String) throws {
        try delete(recordName: submissionRecordName, recordType: CatalogRecordType.submittedQuestion)
    }

    func resolveFlag(recordName: String) throws {
        try delete(recordName: recordName, recordType: CatalogRecordType.questionFlag)
    }

    private func delete(recordName: String, recordType: String) throws {
        _ = try post(operation: "records/modify", body: [
            "operations": [[
                "operationType": "forceDelete",
                "record": ["recordType": recordType, "recordName": recordName] as [String: Any],
            ] as [String: Any]],
        ])
    }
}
#endif
