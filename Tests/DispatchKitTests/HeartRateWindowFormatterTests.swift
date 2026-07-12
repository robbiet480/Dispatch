import Foundation
import Testing

@testable import DispatchKit

@Suite("HeartRateWindowFormatter")
struct HeartRateWindowFormatterTests {
    private func reading(_ type: String, _ value: Double) -> HealthReading {
        HealthReading(type: type, value: value, unit: "bpm")
    }

    @Test("full window renders delta plus range")
    func fullWindow() {
        let readings = [
            reading(HeartRateWindowFormatter.startType, 72),
            reading(HeartRateWindowFormatter.endType, 88),
            reading(HeartRateWindowFormatter.minType, 64),
            reading(HeartRateWindowFormatter.maxType, 112),
        ]
        #expect(HeartRateWindowFormatter.detailLine(from: readings)
            == "72 → 88 bpm (+16) · low 64 · high 112")
    }

    @Test("existing heartRateAvg folds into the line")
    func foldsAvg() {
        let readings = [
            reading(HeartRateWindowFormatter.startType, 72),
            reading(HeartRateWindowFormatter.endType, 88),
            reading(HeartRateWindowFormatter.minType, 64),
            reading(HeartRateWindowFormatter.maxType, 112),
            reading("heartRateAvg", 84.6),
        ]
        #expect(HeartRateWindowFormatter.detailLine(from: readings)
            == "72 → 88 bpm (+16) · low 64 · high 112 · avg 85")
    }

    @Test("avg alone is not a window — yields nil")
    func avgAlone() {
        #expect(HeartRateWindowFormatter.detailLine(from: [reading("heartRateAvg", 80)]) == nil)
    }

    @Test("negative delta renders with minus sign")
    func negativeDelta() {
        let readings = [
            reading(HeartRateWindowFormatter.startType, 90),
            reading(HeartRateWindowFormatter.endType, 71),
        ]
        #expect(HeartRateWindowFormatter.detailLine(from: readings) == "90 → 71 bpm (-19)")
    }

    @Test("zero delta renders plus-minus zero")
    func zeroDelta() {
        let readings = [
            reading(HeartRateWindowFormatter.startType, 70),
            reading(HeartRateWindowFormatter.endType, 70),
        ]
        #expect(HeartRateWindowFormatter.detailLine(from: readings) == "70 → 70 bpm (±0)")
    }

    @Test("min and max only renders the range line")
    func rangeOnly() {
        let readings = [
            reading(HeartRateWindowFormatter.minType, 64),
            reading(HeartRateWindowFormatter.maxType, 112),
        ]
        #expect(HeartRateWindowFormatter.detailLine(from: readings) == "low 64 · high 112 bpm")
    }

    @Test("values round to whole bpm")
    func rounding() {
        let readings = [
            reading(HeartRateWindowFormatter.startType, 71.6),
            reading(HeartRateWindowFormatter.endType, 88.3),
        ]
        #expect(HeartRateWindowFormatter.detailLine(from: readings) == "72 → 88 bpm (+16)")
    }

    @Test("no window readings yields nil")
    func absent() {
        #expect(HeartRateWindowFormatter.detailLine(from: []) == nil)
        let unrelated = [reading("heartRateAvg", 80), reading("steps", 1000)]
        #expect(HeartRateWindowFormatter.detailLine(from: unrelated) == nil)
    }

    @Test("a lone boundary reading is not enough for a delta")
    func loneBoundary() {
        // Start without end (or vice versa) can't make an honest delta line;
        // with no min/max either, the row is absent.
        #expect(HeartRateWindowFormatter.detailLine(
            from: [reading(HeartRateWindowFormatter.startType, 72)]) == nil)
        #expect(HeartRateWindowFormatter.detailLine(
            from: [reading(HeartRateWindowFormatter.endType, 88)]) == nil)
    }
}
