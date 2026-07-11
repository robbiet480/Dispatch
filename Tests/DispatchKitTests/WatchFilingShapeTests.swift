import Foundation
import SwiftData
import Testing
@testable import DispatchKit

// Plan 19: the watch filing path's report shape, exercised at the kit layer
// the watch target calls into (ReportBuilder with the watch's trigger and a
// watch-capable outcome set). Serialized: DeviceIdentity.deviceName is
// process-global injected state.
@Suite(.serialized)
struct WatchFilingShapeTests {
    @Test func watchFilingShapeCarriesTriggerProvenanceAndOnlyWatchSensors() throws {
        let container = try DispatchStore.inMemoryContainer()
        let context = ModelContext(container)

        // A representative watch capture: some sensors captured, one timed
        // out; phone-only kinds are ABSENT from the outcome set entirely.
        let outcomes: [SensorKind: SensorOutcome] = [
            .battery: .captured(.battery(0.66)),
            .altitude: .captured(.altitude(12)),
            .healthSteps: .captured(.health([HealthReading(type: "steps", value: 900, unit: "count")])),
            .weather: .unavailable(reason: "timed out"),
            .location: .disabled,
        ]
        let question = QuestionRef(uniqueIdentifier: "q-yesno", prompt: "Are you working?", type: .yesNo)
        let report = try DeviceIdentityGate.withDeviceName("Apple Watch") {
            try ReportBuilder.save(
                kind: .regular, trigger: .watch, date: Date(), timeZone: .current,
                outcomes: outcomes,
                answers: [AnswerDraft(question: question, value: .options(["Yes"]))],
                in: context
            )
        }

        #expect(report.trigger == .watch)
        #expect(report.sourceDeviceModel == DeviceIdentity.model)
        #expect(report.sourceDeviceName == "Apple Watch")
        #expect(report.battery == 0.66)
        #expect(report.altitudeMeters == 12)
        #expect(report.health.map(\.type) == ["steps"])
        // Unavailable/disabled sensors are absent, not errored.
        #expect(report.weather == nil)
        #expect(report.location == nil)
        // Phone-only sensors were never in the outcome set → nil/empty.
        #expect(report.photos.isEmpty)
        #expect(report.audio == nil)
        #expect(report.connection == nil)
        #expect(report.focus == nil)
        // The single answer recorded as an options response.
        #expect(report.responses?.count == 1)
        #expect(report.responses?.first?.answeredOptions == ["Yes"])
    }
}
