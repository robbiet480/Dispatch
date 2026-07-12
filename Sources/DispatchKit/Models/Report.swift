import Foundation
import SwiftData

@Model
public final class Report {
    public var uniqueIdentifier: String = UUID().uuidString
    public var date: Date = Date.distantPast
    public var timeZoneIdentifier: String = "GMT"
    public var kindRaw: String = ReportKind.regular.rawValue
    public var triggerRaw: String = ReportTrigger.manual.rawValue
    /// Original v1 `reportImpetus`, preserved verbatim on import.
    public var legacyImpetus: Int?
    /// Original v1 `sectionIdentifier`, preserved verbatim on import.
    public var legacySectionIdentifier: String?
    public var isBackdated: Bool = false
    public var isDraft: Bool = false
    public var wasInBackground: Bool = false
    public var battery: Double?
    public var altitudeMeters: Double?
    public var connection: Int?
    public var audio: AudioSample?
    public var location: LocationSnapshot?
    public var weather: WeatherObservation?
    public var photos: [PhotoRecord] = []
    public var health: [HealthReading] = []
    public var focus: FocusState?
    /// What was audibly playing at report time (plan 26); nil = nothing audible.
    public var media: MediaSample?
    public var stateOfMindSampleIDs: [String] = []
    /// The PromptGroup this report was filed against (group-scoped survey);
    /// nil for ordinary global reports. Additive, plan 12.
    public var promptGroupID: String?
    /// Device provenance (plan 19, additive): raw hardware identifier of the
    /// filing device via `utsname.machine` (e.g. "iPhone17,1", "Watch7,4").
    /// Stamped at creation by the shared filing path; nil on pre-existing and
    /// imported reports (never restamped).
    public var sourceDeviceModel: String?
    /// Device provenance (plan 19, additive): the filing device's name via
    /// UIDevice/WKInterfaceDevice — the GENERIC name ("iPhone",
    /// "Apple Watch") until the user-assigned-device-name entitlement is
    /// granted (see DeviceIdentity). Nil on pre-existing/imported reports.
    public var sourceDeviceName: String?
    /// Capture-time context metadata (plan 44, #61, additive-optional —
    /// lightweight-migration-safe): flat fields mirroring `CaptureMetadata`,
    /// stamped by ReportBuilder from the app-side reader. Storage/export
    /// surfaced in report DETAIL only — never their own sensors, never
    /// capture-checklist rows (owner design decision on PR #72).
    /// Device Context (zero-permission, gated by the `deviceContext` toggle):
    public var isLowPowerMode: Bool?
    public var screenBrightness: Double?
    public var interfaceStyle: String?
    public var audioOutputRoute: String?
    /// Motion & Fitness (existing OS authorization, gated by the
    /// `motionFitness` toggle):
    public var motionActivity: String?
    public var barometricPressureKPa: Double?

    /// Optional because CloudKit mirroring requires every relationship to be
    /// optional; relaxing optionality (same name/config) is lightweight-migration-safe.
    @Relationship(deleteRule: .cascade, inverse: \Response.report)
    public var responses: [Response]?

    public init() {}

    public var kind: ReportKind {
        get { ReportKind(rawValue: kindRaw) ?? .regular }
        set { kindRaw = newValue.rawValue }
    }

    public var trigger: ReportTrigger {
        get { ReportTrigger(rawValue: triggerRaw) ?? .manual }
        set { triggerRaw = newValue.rawValue }
    }

    public var connectionType: ConnectionType? {
        connection.flatMap(ConnectionType.init(rawValue:))
    }
}
