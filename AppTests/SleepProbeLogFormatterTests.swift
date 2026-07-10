import XCTest

// PLAN-39 TASK 0 PROBE — remove after measurement.
/// Pins the probe's log-line formatter: the lag arithmetic and stage naming
/// are the measurement itself, so a formatting bug would corrupt the spike's
/// findings. Hostless unit bundle — SleepDeliveryProbe.swift is compiled
/// directly into this target (see project.yml).
final class SleepProbeLogFormatterTests: XCTestCase {
    func testStageNamesUseModernSleepAnalysisCases() {
        XCTAssertEqual(SleepProbeLogFormatter.stageName(forValue: 0), "inBed")
        XCTAssertEqual(SleepProbeLogFormatter.stageName(forValue: 1), "asleepUnspecified")
        XCTAssertEqual(SleepProbeLogFormatter.stageName(forValue: 2), "awake")
        XCTAssertEqual(SleepProbeLogFormatter.stageName(forValue: 3), "asleepCore")
        XCTAssertEqual(SleepProbeLogFormatter.stageName(forValue: 4), "asleepDeep")
        XCTAssertEqual(SleepProbeLogFormatter.stageName(forValue: 5), "asleepREM")
        XCTAssertEqual(SleepProbeLogFormatter.stageName(forValue: 99), "unknown(99)")
    }

    func testLagDescriptionFormatsAndSigns() {
        XCTAssertEqual(SleepProbeLogFormatter.lagDescription(42), "42s")
        XCTAssertEqual(SleepProbeLogFormatter.lagDescription(42 * 60 + 11), "42m11s")
        XCTAssertEqual(SleepProbeLogFormatter.lagDescription(2 * 3600 + 5 * 60 + 9), "2h05m09s")
        // Negative lag = sample endDate after the fire (in-progress segment).
        XCTAssertEqual(SleepProbeLogFormatter.lagDescription(-185), "-3m05s")
        XCTAssertEqual(SleepProbeLogFormatter.lagDescription(0), "0s")
    }

    func testFireEntryContainsHeaderAndPerSampleLags() {
        let fire = Date(timeIntervalSince1970: 1_760_000_000)
        let sample = SleepProbeSample(
            value: 5,
            startDate: fire.addingTimeInterval(-2 * 3600),
            endDate: fire.addingTimeInterval(-42 * 60 - 11),
            sourceName: "Robbie's Apple Watch")
        let entry = SleepProbeLogFormatter.fireEntry(
            fireDate: fire, appState: "background", samples: [sample])

        let lines = entry.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("fire appState=background samples(24h)=1"))
        XCTAssertTrue(lines[1].contains("asleepREM"))
        XCTAssertTrue(lines[1].contains("source=\"Robbie's Apple Watch\""))
        XCTAssertTrue(lines[1].hasSuffix("lag=42m11s"))
        XCTAssertTrue(entry.hasSuffix("\n"), "entries are appended to a log file — each must end with a newline")
    }

    func testFireEntryWithNoSamplesIsSingleHeaderLine() {
        let entry = SleepProbeLogFormatter.fireEntry(
            fireDate: Date(), appState: "active", samples: [])
        XCTAssertEqual(entry.split(separator: "\n").count, 1)
        XCTAssertTrue(entry.contains("samples(24h)=0"))
    }
}
