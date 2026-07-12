import Foundation
import SwiftData
import Testing
@testable import DispatchKit

// Plan 37: pure provenance aggregation, cumulative dedupe totals, and the
// diagnostics dump renderer. The renderer's privacy contract — it can only
// ever see already-aggregated (name, model) pairs, never report content — is
// pinned here behaviorally by the sentinel test.
struct SyncDiagnosticsReportTests {
    // MARK: - Provenance breakdown

    @Test func breakdownBucketsAndSortsDeterministically() {
        let devices: [(name: String?, model: String?)] = [
            ("Robbie's iPhone", "iPhone17,1"),
            ("Robbie's iPhone", "iPhone17,1"),
            (nil, "Watch7,4"),
            (nil, "Watch7,4"),
            (nil, "Watch7,4"),
            (nil, nil),
        ]
        let result = DeviceProvenance.breakdown(devices)
        // Sorted count-descending, then label-ascending.
        #expect(result.count == 3)
        #expect(result[0].label == "Watch7,4")
        #expect(result[0].count == 3)
        #expect(result[1].label == "Robbie's iPhone")
        #expect(result[1].count == 2)
        #expect(result[2].label == "Unknown device")
        #expect(result[2].count == 1)
    }

    @Test func breakdownEmptyInputIsEmpty() {
        #expect(DeviceProvenance.breakdown([]).isEmpty)
    }

    @Test func breakdownPrefersNameThenModel() {
        let result = DeviceProvenance.breakdown([(nil, "iPhone17,1"), ("Named", nil)])
        let labels = Set(result.map(\.label))
        #expect(labels == ["iPhone17,1", "Named"])
    }

    // MARK: - Dedupe totals

    @Test func absorbSumsPerTypeAndRecordsLastPass() {
        var totals = DedupeTotals()
        var first = DedupeSummary()
        first.questionsRemoved = 2
        first.tokensRemoved = 1
        var second = DedupeSummary()
        second.questionsRemoved = 3
        second.peopleRemoved = 4

        let date1 = Date(timeIntervalSince1970: 1_000)
        let date2 = Date(timeIntervalSince1970: 2_000)
        totals.absorb(first, at: date1)
        totals.absorb(second, at: date2)

        #expect(totals.questions == 5)
        #expect(totals.tokens == 1)
        #expect(totals.people == 4)
        #expect(totals.lastPassDate == date2)
        #expect(totals.lastPassSummary == second)
    }

    @Test func dedupeTotalsRoundTrip() throws {
        var totals = DedupeTotals()
        var summary = DedupeSummary()
        summary.reportsRemoved = 7
        totals.absorb(summary, at: Date(timeIntervalSince1970: 500))
        let data = try JSONEncoder().encode(totals)
        let restored = try JSONDecoder().decode(DedupeTotals.self, from: data)
        #expect(restored == totals)
    }

    // MARK: - Render

    @Test func renderContainsHeaderEventsAndTotals() {
        var totals = DedupeTotals()
        var summary = DedupeSummary()
        summary.reportsRemoved = 2
        totals.absorb(summary, at: Date(timeIntervalSince1970: 1_700_000_000))
        let events = [
            SyncEventRecord(
                date: Date(timeIntervalSince1970: 1_700_000_100),
                kindRaw: SyncEventKind.dedupePass.rawValue,
                succeeded: true, detail: "removed 2 duplicates"
            ),
            SyncEventRecord(
                date: Date(timeIntervalSince1970: 1_700_000_200),
                kindRaw: "futureKind", succeeded: nil, detail: "opaque"
            ),
        ]
        let dump = SyncDiagnosticsReport.render(
            appVersion: "1.0 (25)",
            osVersion: "iOS 26.0",
            deviceModel: "iPhone17,1",
            syncEnabled: true,
            syncActive: true,
            accountStatusText: "Available",
            events: events,
            dedupeTotals: totals,
            provenance: [(label: "Robbie's iPhone", count: 5)],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        #expect(dump.contains("1.0 (25)"))
        #expect(dump.contains("iOS 26.0"))
        #expect(dump.contains("iPhone17,1"))
        #expect(dump.contains("Available"))
        // Known kind shows its displayName; unknown kind shows the raw string.
        #expect(dump.contains(SyncEventKind.dedupePass.displayName))
        #expect(dump.contains("futureKind"))
        #expect(dump.contains("removed 2 duplicates"))
        #expect(dump.contains("Robbie's iPhone"))
        // Reports-removed lifetime total is surfaced.
        #expect(dump.contains("2"))
    }

    /// The EVENTS section renders in the exact order it receives (the caller
    /// pre-sorts newest-first). Render must NOT re-reverse — doing so would
    /// list oldest-first, contradicting the "newest first" label and the
    /// on-screen list.
    @Test func renderPreservesEventOrderNewestFirst() {
        let events = [
            SyncEventRecord(
                date: Date(timeIntervalSince1970: 1_700_000_200),
                kindRaw: "newerEvent", succeeded: true, detail: nil
            ),
            SyncEventRecord(
                date: Date(timeIntervalSince1970: 1_700_000_100),
                kindRaw: "olderEvent", succeeded: true, detail: nil
            ),
        ]
        let dump = SyncDiagnosticsReport.render(
            appVersion: "1.0 (25)", osVersion: "iOS 26.0", deviceModel: "iPhone17,1",
            syncEnabled: true, syncActive: true, accountStatusText: "Available",
            events: events, dedupeTotals: DedupeTotals(), provenance: [],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        let newer = try! #require(dump.range(of: "newerEvent"))
        let older = try! #require(dump.range(of: "olderEvent"))
        #expect(newer.lowerBound < older.lowerBound,
                "events must render in the newest-first order they are passed")
    }

    // MARK: - Privacy pin (executable form of the privacy decision)

    @Test func renderNeverLeaksReportContent() throws {
        // Build REAL reports whose answers + question prompts carry sentinels,
        // then derive exactly what the app passes the renderer: (name, model)
        // provenance pairs. The sentinel must not survive into the dump — the
        // renderer has no Report parameter by construction, and this test is
        // the behavioral half of that structural guarantee. If a future change
        // threads report content into the renderer, this fails.
        let sentinelAnswer = "SENTINEL-ANSWER-TEXT"
        let sentinelPrompt = "SENTINEL-QUESTION-PROMPT"

        let container = try DispatchStore.inMemoryContainer()
        let context = ModelContext(container)
        // Gate, don't set directly: deviceName is process-global and suites
        // run in parallel (see DeviceIdentityGate).
        let reports = try DeviceIdentityGate.withDeviceName("Robbie's iPhone") {
            let ref = QuestionRef(
                uniqueIdentifier: "q-note", prompt: sentinelPrompt, type: .note
            )
            _ = try ReportBuilder.save(
                kind: .regular, trigger: .manual, date: Date(), timeZone: .current,
                outcomes: [:],
                answers: [AnswerDraft(question: ref, value: .note(sentinelAnswer))],
                in: context
            )
            return try context.fetch(FetchDescriptor<Report>())
        }
        let pairs = reports.map { (name: $0.sourceDeviceName, model: $0.sourceDeviceModel) }
        let provenance = DeviceProvenance.breakdown(pairs)

        let dump = SyncDiagnosticsReport.render(
            appVersion: "1.0 (25)",
            osVersion: "iOS 26.0",
            deviceModel: "iPhone17,1",
            syncEnabled: true,
            syncActive: true,
            accountStatusText: "Available",
            events: [],
            dedupeTotals: DedupeTotals(),
            provenance: provenance,
            generatedAt: Date()
        )

        #expect(!dump.contains(sentinelAnswer))
        #expect(!dump.contains(sentinelPrompt))
        // The device name (provenance label) IS expected in the dump.
        #expect(dump.contains("Robbie's iPhone"))
    }
}
