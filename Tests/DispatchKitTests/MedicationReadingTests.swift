import Foundation
import Testing
@testable import DispatchKit

@Test func medicationTypeRoundTrips() {
    let type = MedicationReading.type(status: "taken", name: "Ibuprofen")
    #expect(type == "medication.taken.Ibuprofen")
    #expect(MedicationReading.parse(type) == .init(status: "taken", name: "Ibuprofen"))
}

@Test func medicationNameWithDotsSurvivesParsing() {
    let type = MedicationReading.type(status: "skipped", name: "Vitamin D3 2.5mg")
    #expect(MedicationReading.parse(type) == .init(status: "skipped", name: "Vitamin D3 2.5mg"))
}

@Test func nonMedicationTypesParseAsNil() {
    #expect(MedicationReading.parse("steps") == nil)
    #expect(MedicationReading.parse("workout.37") == nil)
    // Pre-plan-14 placeholder type: no status/name payload.
    #expect(MedicationReading.parse("medicationDose") == nil)
    #expect(MedicationReading.parse("medication.") == nil)
    #expect(MedicationReading.parse("medication.taken.") == nil)
}

@Test func detailLineFormatsQuantityAndStatus() {
    #expect(MedicationReading.detailLine(type: "medication.taken.Ibuprofen", value: 1, unit: "count")
        == "Ibuprofen · 1 · taken")
    #expect(MedicationReading.detailLine(type: "medication.skipped.Insulin", value: 2.5, unit: "mL")
        == "Insulin · 2.5 mL · skipped")
    #expect(MedicationReading.detailLine(type: "steps", value: 100, unit: "count") == nil)
}
