#if os(macOS)
import XCTest
import DispatchKit
@testable import dispatch_mod

/// The CloudKit Web Services JSON bridge (`fieldJSON` / `fieldValues`) must
/// round-trip every `CatalogFieldValue` case — plan 41 adds `.double` for
/// the input-style bounds (`inputMin`/`inputMax`/`inputStep`).
final class ModFieldJSONTests: XCTestCase {
    func testDoubleFieldJSONShape() throws {
        let json = CloudKitWebClient.fieldJSON(["inputMin": .double(2.5)])
        let entry = try XCTUnwrap(json["inputMin"] as? [String: Any])
        XCTAssertEqual(entry["type"] as? String, "DOUBLE")
        XCTAssertEqual(entry["value"] as? Double, 2.5)
    }

    func testDoubleFieldValuesDecodes() {
        let fields = CloudKitWebClient.fieldValues([
            "inputMin": ["value": 2.5, "type": "DOUBLE"],
        ])
        XCTAssertEqual(fields["inputMin"], .double(2.5))
    }

    func testDoubleFieldValuesToleratesWholeNumberSerializedAsInt() {
        // CKWS may serialize a whole number without a decimal point;
        // JSONSerialization then bridges it as Int, not Double.
        let fields = CloudKitWebClient.fieldValues([
            "inputMax": ["value": 100, "type": "DOUBLE"],
        ])
        XCTAssertEqual(fields["inputMax"], .double(100))
    }

    /// Serializes `fieldJSON` output to JSON bytes and back, matching the
    /// real wire: `fieldValues` consumes `JSONSerialization` output (NSNumber
    /// values), not Swift-native dictionaries.
    private func overTheWire(_ json: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testConfiguredSubmissionRoundTripsThroughWebServicesJSON() throws {
        let original = SubmittedQuestion(
            recordName: "sub-json-1", prompt: "Stress level?",
            typeRaw: QuestionType.number.rawValue, choices: [],
            creditName: "Robbie", submittedAt: Date(timeIntervalSince1970: 1_700_000_000),
            inputStyle: "scale", defaultAnswer: "3", placeholder: "1–5",
            inputMin: 1, inputMax: 5, inputStep: 1
        )
        let wire = try overTheWire(CloudKitWebClient.fieldJSON(original.fields))
        let restored = try XCTUnwrap(SubmittedQuestion(
            recordName: "sub-json-1", fields: CloudKitWebClient.fieldValues(wire)
        ))
        XCTAssertEqual(restored, original)
    }

    func testUnconfiguredSubmissionRoundTripsUnchanged() throws {
        let original = SubmittedQuestion(
            recordName: "sub-json-2", prompt: "Coffee?",
            typeRaw: QuestionType.yesNo.rawValue, choices: [],
            creditName: nil, submittedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let json = CloudKitWebClient.fieldJSON(original.fields)
        for key in ["inputStyle", "defaultAnswer", "placeholder", "inputMin", "inputMax", "inputStep"] {
            XCTAssertNil(json[key], "nil \(key) must not be emitted")
        }
        let restored = try XCTUnwrap(SubmittedQuestion(
            recordName: "sub-json-2", fields: CloudKitWebClient.fieldValues(overTheWire(json))
        ))
        XCTAssertEqual(restored, original)
    }
}
#endif
