import Foundation
import Testing
@testable import DispatchKit

// Plan 37: the sync diagnostics event log is a bounded, persisted ring buffer
// of sanitized records. Kit-side it's pure Foundation — no SwiftData/CloudKit.
struct SyncEventLogTests {
    // MARK: - Ring semantics

    @Test func appendingBeyondCapacityKeepsNewestAndDropsOldest() {
        var log = SyncEventLog(capacity: 50)
        for index in 0..<60 {
            log.append(SyncEventRecord(
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                kindRaw: SyncEventKind.remoteChange.rawValue,
                succeeded: nil, detail: "\(index)"
            ))
        }
        #expect(log.records.count == 50)
        // Oldest ten dropped; order preserved oldest-first.
        #expect(log.records.first?.detail == "10")
        #expect(log.records.last?.detail == "59")
    }

    // MARK: - Round-trip

    @Test func roundTripPreservesRecordsIncludingNils() throws {
        var log = SyncEventLog(capacity: 50)
        log.append(SyncEventRecord(
            date: Date(timeIntervalSince1970: 100),
            kindRaw: SyncEventKind.dedupePass.rawValue,
            succeeded: true, detail: "removed 3"
        ))
        log.append(SyncEventRecord(
            date: Date(timeIntervalSince1970: 200),
            kindRaw: SyncEventKind.remoteChange.rawValue,
            succeeded: nil, detail: nil
        ))
        let data = try #require(log.encoded())
        let restored = SyncEventLog(decodingFrom: data)
        #expect(restored.records.count == 2)
        #expect(restored.records[0].succeeded == true)
        #expect(restored.records[0].detail == "removed 3")
        #expect(restored.records[1].succeeded == nil)
        #expect(restored.records[1].detail == nil)
        #expect(restored.records[1].kind == .remoteChange)
    }

    // MARK: - Leniency

    @Test func unknownKindDecodesAndReEncodesUntouched() throws {
        // A record from a newer build carrying a kind this build doesn't know.
        let record = SyncEventRecord(
            date: Date(timeIntervalSince1970: 300),
            kindRaw: "futureKind", succeeded: false, detail: "x"
        )
        var log = SyncEventLog(capacity: 50)
        log.append(record)
        let data = try #require(log.encoded())
        let restored = SyncEventLog(decodingFrom: data)
        #expect(restored.records.count == 1)
        // Typed accessor is nil for an unknown raw...
        #expect(restored.records[0].kind == nil)
        // ...but the raw string survives untouched.
        #expect(restored.records[0].kindRaw == "futureKind")
        #expect(restored.records[0].succeeded == false)
    }

    // MARK: - Corrupt data

    @Test func garbageDataYieldsEmptyLog() {
        let garbage = Data([0x00, 0x01, 0x02, 0xff, 0xfe])
        let log = SyncEventLog(decodingFrom: garbage)
        #expect(log.records.isEmpty)
    }

    @Test func nilDataYieldsEmptyLog() {
        let log = SyncEventLog(decodingFrom: nil)
        #expect(log.records.isEmpty)
    }

    // MARK: - Sanitize

    @Test func sanitizeTruncatesToTwoHundredCharsAndDropsUserInfo() {
        let longDescription = String(repeating: "A", count: 500)
        let error = NSError(
            domain: "TestDomain", code: 42,
            userInfo: [
                NSLocalizedDescriptionKey: longDescription,
                "secretKey": "SECRET-USERINFO-VALUE",
            ]
        )
        let sanitized = SyncEventRecord.sanitize(error: error)
        #expect(sanitized.hasPrefix("TestDomain(42): "))
        // userInfo values never leak.
        #expect(!sanitized.contains("SECRET-USERINFO-VALUE"))
        // The description portion is truncated to 200 chars.
        let descriptionPortion = sanitized.replacingOccurrences(of: "TestDomain(42): ", with: "")
        #expect(descriptionPortion.count == 200)
    }
}
