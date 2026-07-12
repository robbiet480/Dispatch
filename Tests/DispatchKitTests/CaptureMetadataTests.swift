import Foundation
import SwiftData
import Testing
@testable import DispatchKit

// MARK: - Formatting helpers (plan 44, #61)

@Test func brightnessClampsIntoUnitRange() {
    #expect(CaptureMetadataFormatting.normalizedBrightness(0.5) == 0.5)
    #expect(CaptureMetadataFormatting.normalizedBrightness(-0.1) == 0)
    #expect(CaptureMetadataFormatting.normalizedBrightness(1.4) == 1)
    #expect(CaptureMetadataFormatting.normalizedBrightness(.nan) == nil)
    #expect(CaptureMetadataFormatting.normalizedBrightness(.infinity) == nil)
}

@Test func motionActivityLabelPicksMostSpecificMode() {
    // Overlapping flags: the fastest/most specific mode wins.
    #expect(CaptureMetadataFormatting.motionActivityLabel(
        stationary: false, walking: true, running: false,
        cycling: false, automotive: true, unknown: false) == "automotive")
    #expect(CaptureMetadataFormatting.motionActivityLabel(
        stationary: true, walking: true, running: false,
        cycling: false, automotive: false, unknown: false) == "walking")
    #expect(CaptureMetadataFormatting.motionActivityLabel(
        stationary: true, walking: false, running: false,
        cycling: false, automotive: false, unknown: false) == "stationary")
    #expect(CaptureMetadataFormatting.motionActivityLabel(
        stationary: false, walking: false, running: false,
        cycling: false, automotive: false, unknown: true) == "unknown")
    // No classification at all → nil, not "unknown".
    #expect(CaptureMetadataFormatting.motionActivityLabel(
        stationary: false, walking: false, running: false,
        cycling: false, automotive: false, unknown: false) == nil)
}

@Test func audioRouteLabelStripsRedundantOutputSuffix() {
    #expect(CaptureMetadataFormatting.audioRouteLabel(portType: "BluetoothA2DPOutput") == "BluetoothA2DP")
    #expect(CaptureMetadataFormatting.audioRouteLabel(portType: "Speaker") == "Speaker")
    #expect(CaptureMetadataFormatting.audioRouteLabel(portType: "Headphones") == "Headphones")
    #expect(CaptureMetadataFormatting.audioRouteLabel(portType: "AirPlay") == "AirPlay")
    // Degenerate raw value stays untouched rather than emptying out.
    #expect(CaptureMetadataFormatting.audioRouteLabel(portType: "Output") == "Output")
}

@Test func pressureRejectsNonPositiveAndNonFinite() {
    #expect(CaptureMetadataFormatting.validPressureKPa(101.325) == 101.325)
    #expect(CaptureMetadataFormatting.validPressureKPa(0) == nil)
    #expect(CaptureMetadataFormatting.validPressureKPa(-1) == nil)
    #expect(CaptureMetadataFormatting.validPressureKPa(.nan) == nil)
}

// MARK: - ReportBuilder mapping

@Test func reportBuilderStampsCaptureMetadataFlatFields() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    var metadata = CaptureMetadata()
    metadata.isLowPowerMode = true
    metadata.screenBrightness = 0.8
    metadata.interfaceStyle = "dark"
    metadata.audioOutputRoute = "BluetoothA2DP"
    metadata.motionActivity = "walking"
    metadata.barometricPressureKPa = 101.3

    let report = try ReportBuilder.save(
        kind: .regular, trigger: .manual, date: Date(), timeZone: .current,
        outcomes: [:], answers: [], in: context, metadata: metadata)

    #expect(report.isLowPowerMode == true)
    #expect(report.screenBrightness == 0.8)
    #expect(report.interfaceStyle == "dark")
    #expect(report.audioOutputRoute == "BluetoothA2DP")
    #expect(report.motionActivity == "walking")
    #expect(report.barometricPressureKPa == 101.3)
}

@Test func reportBuilderDefaultsMetadataToAllNil() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let report = try ReportBuilder.save(
        kind: .regular, trigger: .manual, date: Date(), timeZone: .current,
        outcomes: [:], answers: [], in: context)
    #expect(report.isLowPowerMode == nil)
    #expect(report.screenBrightness == nil)
    #expect(report.interfaceStyle == nil)
    #expect(report.audioOutputRoute == nil)
    #expect(report.motionActivity == nil)
    #expect(report.barometricPressureKPa == nil)
}

// MARK: - Location payload extras land on the report

@Test func locationSnapshotMotionExtrasRideTheLocationPayload() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    var snapshot = LocationSnapshot(latitude: 37.7764, longitude: -122.4231)
    snapshot.speed = 5.5
    snapshot.speedAccuracy = 0.4
    snapshot.course = 180
    snapshot.courseAccuracy = 2.5
    snapshot.floorLevel = 3
    snapshot.isSimulatedBySoftware = false
    snapshot.isProducedByAccessory = false
    snapshot.trueHeading = 45
    snapshot.magneticHeading = 44.2
    snapshot.headingAccuracy = 5

    let report = try ReportBuilder.save(
        kind: .regular, trigger: .manual, date: Date(), timeZone: .current,
        outcomes: [.location: .captured(.location(snapshot))],
        answers: [], in: context)

    #expect(report.location?.speed == 5.5)
    #expect(report.location?.speedAccuracy == 0.4)
    #expect(report.location?.course == 180)
    #expect(report.location?.courseAccuracy == 2.5)
    #expect(report.location?.floorLevel == 3)
    #expect(report.location?.isSimulatedBySoftware == false)
    #expect(report.location?.isProducedByAccessory == false)
    #expect(report.location?.trueHeading == 45)
    #expect(report.location?.magneticHeading == 44.2)
    #expect(report.location?.headingAccuracy == 5)
}

// MARK: - V2 round-trip

@Test func v2RoundTripsCaptureMetadataAndLocationExtras() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let report = Report()
    report.date = Date(timeIntervalSince1970: 1_780_000_000)
    report.isLowPowerMode = true
    report.screenBrightness = 0.8
    report.interfaceStyle = "dark"
    report.audioOutputRoute = "Speaker"
    report.motionActivity = "cycling"
    report.barometricPressureKPa = 100.9
    var snapshot = LocationSnapshot(latitude: 37.7764, longitude: -122.4231)
    snapshot.speed = 5.5
    snapshot.course = 180
    snapshot.floorLevel = 2
    snapshot.trueHeading = 45
    report.location = snapshot
    context.insert(report)
    try context.save()

    let data = try V2Exporter.exportData(from: context)
    let json = String(decoding: data, as: UTF8.self)
    // Grouped blocks in the JSON.
    #expect(json.contains("\"deviceState\""))
    #expect(json.contains("\"motion\""))
    #expect(json.contains("\"floorLevel\""))

    let importContainer = try DispatchStore.inMemoryContainer()
    let importContext = ModelContext(importContainer)
    _ = try V2Importer.importExport(data, into: importContext)
    let imported = try #require(try importContext.fetch(FetchDescriptor<Report>()).first)
    #expect(imported.isLowPowerMode == true)
    #expect(imported.screenBrightness == 0.8)
    #expect(imported.interfaceStyle == "dark")
    #expect(imported.audioOutputRoute == "Speaker")
    #expect(imported.motionActivity == "cycling")
    #expect(imported.barometricPressureKPa == 100.9)
    #expect(imported.location?.speed == 5.5)
    #expect(imported.location?.course == 180)
    #expect(imported.location?.floorLevel == 2)
    #expect(imported.location?.trueHeading == 45)
}

@Test func v2OmitsEmptyMetadataBlocks() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let report = Report()
    report.date = Date(timeIntervalSince1970: 1_780_000_000)
    context.insert(report)
    try context.save()

    let json = String(decoding: try V2Exporter.exportData(from: context), as: UTF8.self)
    #expect(!json.contains("\"deviceState\""))
    #expect(!json.contains("\"motion\""))

    // Pre-metadata v2 files import cleanly with nil fields.
    let importContainer = try DispatchStore.inMemoryContainer()
    let importContext = ModelContext(importContainer)
    _ = try V2Importer.importExport(try V2Exporter.exportData(from: context), into: importContext)
    let imported = try #require(try importContext.fetch(FetchDescriptor<Report>()).first)
    #expect(imported.isLowPowerMode == nil)
    #expect(imported.motionActivity == nil)
}

// MARK: - Detail rows

@Test func detailDegreeRowsWrapAt360() {
    var snapshot = LocationSnapshot(latitude: 0, longitude: 0)
    snapshot.course = 359.6
    snapshot.trueHeading = 45
    let rows = ContextMetadataDetail.locationRows(snapshot)
    let course = rows.first { $0.label == "Course" }
    // 359.6 rounds to 360 → wraps to 0°, never renders "360°".
    #expect(course?.value == "0° N")
    let heading = rows.first { $0.label == "Heading" }
    #expect(heading?.value == "45° NE")
}

@Test func detailRowsHideNilFieldsAndQuietSourceFlags() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let report = Report()
    context.insert(report)
    // No metadata at all → no context rows.
    #expect(ContextMetadataDetail.contextRows(for: report).isEmpty)
    // A normal (non-simulated, non-accessory) fix renders no source rows.
    var snapshot = LocationSnapshot(latitude: 0, longitude: 0)
    snapshot.isSimulatedBySoftware = false
    snapshot.isProducedByAccessory = false
    #expect(ContextMetadataDetail.locationRows(snapshot).isEmpty)
    #expect(ContextMetadataDetail.locationRows(nil).isEmpty)
}

// MARK: - Toggle defaults

@Test func metadataTogglesDefaultToEnabled() {
    let defaults = UserDefaults(suiteName: "metadata-toggle-test-\(UUID().uuidString)")!
    let settings = SensorSettings(defaults: defaults)
    #expect(settings.isEnabled(.motionFitness))
    #expect(settings.isEnabled(.deviceContext))
    settings.setEnabled(.deviceContext, false)
    #expect(!settings.isEnabled(.deviceContext))
}
