import Foundation

/// Shared knobs for the two CLMonitor-backed trigger kinds (plan 45, issues
/// #56 / #60). Kept in one place so places and beacons agree on the delay
/// preset list and the honest-radius floor.
public enum MonitorDelay {
    /// The delay presets offered in the editor (minutes after the event).
    /// 0 = fire immediately; the others schedule the prompt at event + N and
    /// a contradicting event cancels it if `cancelOnContradiction`.
    public static let allowedMinutes = [0, 5, 10, 15, 30, 60]
    /// CLMonitor geographic callbacks get unreliable below ~100 m, so radii
    /// are clamped to this floor (surface over false precision).
    public static let floorRadiusMeters = 100.0

    /// Snaps a persisted/imported delay to the nearest offered preset. The
    /// editor's Delay `Picker` only has tags for `allowedMinutes`; seeding it
    /// with an off-list value (a hand-edited/corrupt import) would leave the
    /// control with no matching selection and let the bad value re-save
    /// unchanged. Clamping to the closest preset keeps the Picker well-defined.
    public static func nearestAllowedMinutes(_ minutes: Int) -> Int {
        allowedMinutes.min(by: { abs($0 - minutes) < abs($1 - minutes) }) ?? 0
    }
}

/// Which edge of a monitored condition fires the prompt. Raw values are the
/// stored `monitorDirectionRaw` strings — additive only.
public enum MonitorDirection: String, Codable, Sendable, CaseIterable {
    /// Fires when the condition becomes `.satisfied` — entered the region /
    /// in beacon range. Cancels a pending prompt on `.unsatisfied`.
    case arrival
    /// Fires when the condition becomes `.unsatisfied` — left the region /
    /// out of beacon range. Cancels a pending prompt on `.satisfied`.
    case departure
}

/// A picked place for the `.placeTrigger` schedule kind (#56): a coordinate +
/// radius (metres) and an optional friendly name. Radius is clamped to
/// `MonitorDelay.floorRadiusMeters` at construction so a too-tight radius can
/// never be stored.
public struct MonitorPlaceRegion: Equatable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double
    public var radius: Double
    public var name: String?

    public init(latitude: Double, longitude: Double, radius: Double, name: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.radius = max(MonitorDelay.floorRadiusMeters, radius)
        self.name = name
    }

    /// Decoding path (v2 import / stored JSON) applies the same radius floor —
    /// a hand-edited export can't sneak a sub-floor radius past construction.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let latitude = try container.decode(Double.self, forKey: .latitude)
        let longitude = try container.decode(Double.self, forKey: .longitude)
        let radius = try container.decode(Double.self, forKey: .radius)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        self.init(latitude: latitude, longitude: longitude, radius: radius, name: name)
    }
}

/// A registered iBeacon for the `.beaconTrigger` schedule kind (#60): UUID
/// (required), optional major/minor for finer identity, and an optional
/// friendly name (carried into the report trigger metadata / Beacons list).
public struct MonitorBeaconIdentity: Equatable, Sendable, Codable {
    public var uuid: String
    public var major: Int?
    public var minor: Int?
    public var name: String?

    public init(uuid: String, major: Int? = nil, minor: Int? = nil, name: String? = nil) {
        self.uuid = uuid
        self.major = major
        // A minor is only meaningful alongside a major: CLBeaconIdentityConstraint
        // supports UUID, UUID+major, or UUID+major+minor — never UUID+minor. Drop
        // an orphaned minor so the contract holds for every construction site.
        self.minor = major == nil ? nil : minor
        self.name = name
    }

    // Route decoding (stored fields + imports) through the memberwise init so
    // the same major/minor contract is enforced, not just on in-app editing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            uuid: try c.decode(String.self, forKey: .uuid),
            major: try c.decodeIfPresent(Int.self, forKey: .major),
            minor: try c.decodeIfPresent(Int.self, forKey: .minor),
            name: try c.decodeIfPresent(String.self, forKey: .name))
    }
}

/// Resolved `.placeTrigger` configuration — the region plus the shared
/// direction/delay/cancel knobs. Stored on `PromptGroup` as
/// `placeRegionJSON` + the `monitor*` scalar fields; a missing/corrupt
/// payload makes the failable init return nil so the schedule resolves to
/// `.disabled` (the calendar-rule forward-compat precedent).
public struct PlaceTrigger: Equatable, Sendable {
    public var region: MonitorPlaceRegion
    public var direction: MonitorDirection
    public var delayMinutes: Int
    public var cancelOnContradiction: Bool

    public init(region: MonitorPlaceRegion, direction: MonitorDirection,
                delayMinutes: Int, cancelOnContradiction: Bool) {
        self.region = region
        self.direction = direction
        self.delayMinutes = delayMinutes
        self.cancelOnContradiction = cancelOnContradiction
    }

    public init?(regionJSON: String?, directionRaw: String?,
                 delayMinutes: Int?, cancelOnContradiction: Bool?) {
        guard let region = MonitorPlaceRegion(json: regionJSON),
              let direction = MonitorDirection(rawValue: directionRaw ?? "") else { return nil }
        self.init(region: region, direction: direction,
                  delayMinutes: delayMinutes ?? 0,
                  cancelOnContradiction: cancelOnContradiction ?? true)
    }

    public var regionJSON: String? { region.json }
}

/// Resolved `.beaconTrigger` configuration — the beacon identity plus the
/// shared direction/delay/cancel knobs. Storage/forward-compat mirror
/// `PlaceTrigger`.
public struct BeaconTrigger: Equatable, Sendable {
    public var beacon: MonitorBeaconIdentity
    public var direction: MonitorDirection
    public var delayMinutes: Int
    public var cancelOnContradiction: Bool

    public init(beacon: MonitorBeaconIdentity, direction: MonitorDirection,
                delayMinutes: Int, cancelOnContradiction: Bool) {
        self.beacon = beacon
        self.direction = direction
        self.delayMinutes = delayMinutes
        self.cancelOnContradiction = cancelOnContradiction
    }

    public init?(beaconJSON: String?, directionRaw: String?,
                 delayMinutes: Int?, cancelOnContradiction: Bool?) {
        guard let beacon = MonitorBeaconIdentity(json: beaconJSON),
              !beacon.uuid.isEmpty,
              let direction = MonitorDirection(rawValue: directionRaw ?? "") else { return nil }
        self.init(beacon: beacon, direction: direction,
                  delayMinutes: delayMinutes ?? 0,
                  cancelOnContradiction: cancelOnContradiction ?? true)
    }

    public var beaconJSON: String? { beacon.json }
}

// MARK: - JSON codecs (the scheduledTimesJSON / calendarIdentifiersJSON pattern)

extension MonitorPlaceRegion {
    init?(json: String?) {
        guard let json, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(MonitorPlaceRegion.self, from: data)
        else { return nil }
        self = value
    }

    var json: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension MonitorBeaconIdentity {
    init?(json: String?) {
        guard let json, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(MonitorBeaconIdentity.self, from: data)
        else { return nil }
        self = value
    }

    var json: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
