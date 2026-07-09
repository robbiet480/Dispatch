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
    public var stateOfMindSampleIDs: [String] = []
    /// The PromptGroup this report was filed against (group-scoped survey);
    /// nil for ordinary global reports. Additive, plan 12.
    public var promptGroupID: String?

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
