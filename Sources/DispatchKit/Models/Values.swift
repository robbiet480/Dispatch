import Foundation

public enum ReportKind: String, Codable, Sendable, CaseIterable {
    case regular, wake, sleep
}

public enum ReportTrigger: String, Codable, Sendable, CaseIterable {
    case manual, notification, visitArrival, visitDeparture
    case wake, workoutEnd, widget, control, intent
    /// Filed from the Apple Watch app (plan 19) — additive raw value; older
    /// builds decode it via the `.manual` raw-value fallback.
    case watch
}

/// Raw values 0–2 match the original Reporter export (gist.github.com/dbreunig/9315705).
/// 3+ are additive (plan 26) — NEVER renumber existing cases; old reports keep coarse values.
public enum ConnectionType: Int, Codable, Sendable, CaseIterable {
    case cellular = 0
    case wifi = 1
    case none = 2
    case wired = 3
    case cellular5G = 4
    case cellularLTE = 5
    case cellular3G = 6
    case cellular2G = 7
    case satellite = 8

    public var displayName: String {
        switch self {
        case .none: "None"
        case .wifi: "Wi-Fi"
        case .wired: "Wired"
        case .cellular5G: "5G"
        case .cellularLTE: "LTE"
        case .cellular3G: "3G"
        case .cellular2G: "2G"
        case .cellular: "Cellular"
        case .satellite: "Satellite"
        }
    }

    /// Maps a CTRadioAccessTechnology* constant VALUE to a cellular generation.
    /// Pure string table so DispatchKit stays CoreTelephony-free; the provider
    /// passes serviceCurrentRadioAccessTechnology's value straight through.
    /// (The constants' runtime values equal their names — verified at implementation;
    /// see ConnectionProvider.classify.)
    public static func cellular(fromRadioAccessTechnology technology: String?) -> ConnectionType {
        switch technology {
        case "CTRadioAccessTechnologyNR", "CTRadioAccessTechnologyNRNSA":
            .cellular5G
        case "CTRadioAccessTechnologyLTE":
            .cellularLTE
        case "CTRadioAccessTechnologyWCDMA", "CTRadioAccessTechnologyHSDPA",
             "CTRadioAccessTechnologyHSUPA", "CTRadioAccessTechnologyCDMAEVDORev0",
             "CTRadioAccessTechnologyCDMAEVDORevA", "CTRadioAccessTechnologyCDMAEVDORevB",
             "CTRadioAccessTechnologyeHRPD":
            .cellular3G
        case "CTRadioAccessTechnologyEdge", "CTRadioAccessTechnologyGPRS",
             "CTRadioAccessTechnologyCDMA1x":
            .cellular2G
        default:
            .cellular
        }
    }
}

public enum MediaSource: String, Codable, Sendable {
    case appleMusic, spotify, otherAudio
    public var displayName: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .otherAudio: "Other audio"
        }
    }
}

public enum MediaPlaybackState: Int, Codable, Sendable {
    case stopped = 0, playing = 1, paused = 2
}

/// What was audibly playing at report time (plan 26). Source and playback
/// state are stored raw (the Report.connection/connectionType precedent):
/// unknown values from future exports import, persist, and re-export
/// untouched. A nil `Report.media` means nothing was audible — the provider
/// emits no sample for silence so payloads stay lean.
///
/// NOTE (plan-26 deviation, 2026-07-10): the plan named these `sourceRaw`/
/// `playbackStateRaw` with renamed CodingKeys ("source"/"playbackState").
/// SwiftData's composite-value storage persists stored properties by NAME and
/// silently DROPS properties whose names don't match a coding key (observed:
/// source/playbackState came back empty after a save/fetch round-trip; the
/// synthesized decoder then trapped with SIGTRAP). So the stored properties
/// carry the wire names directly and the typed accessors are `sourceType`/
/// `playbackStateType` — same raw-leniency contract, SwiftData-safe.
public struct MediaSample: Codable, Hashable, Sendable {
    /// Raw MediaSource value; unknown values are preserved verbatim.
    public var source: String
    public var title: String?
    public var artist: String?
    public var album: String?
    /// Raw MediaPlaybackState value; unknown values are preserved verbatim.
    public var playbackState: Int

    public init(source: MediaSource, title: String? = nil, artist: String? = nil,
                album: String? = nil, playbackState: MediaPlaybackState = .playing) {
        self.source = source.rawValue
        self.title = title
        self.artist = artist
        self.album = album
        self.playbackState = playbackState.rawValue
    }

    public var sourceType: MediaSource? { MediaSource(rawValue: source) }
    public var playbackStateType: MediaPlaybackState? { MediaPlaybackState(rawValue: playbackState) }

    /// Report-detail line, e.g. "Song — Artist, via Spotify"; the other-audio
    /// floor has no metadata and renders as "Audio playing".
    public var detailLine: String {
        guard sourceType != .otherAudio else { return "Audio playing" }
        let song = [title, artist].compactMap(\.self).joined(separator: " — ")
        let via = sourceType.map { ", via \($0.displayName)" } ?? ""
        return song.isEmpty ? "Media playing\(via)" : "\(song)\(via)"
    }
}

public struct AudioSample: Codable, Hashable, Sendable {
    public var avg: Double
    public var peak: Double
    public init(avg: Double, peak: Double) { self.avg = avg; self.peak = peak }
}

public struct Placemark: Codable, Hashable, Sendable {
    public var name: String?
    public var thoroughfare: String?
    public var subThoroughfare: String?
    public var locality: String?
    public var subLocality: String?
    public var administrativeArea: String?
    public var subAdministrativeArea: String?
    public var postalCode: String?
    public var country: String?
    public init() {}
}

public struct LocationSnapshot: Codable, Hashable, Sendable {
    // latitude/longitude are deliberately optional: coordinate-less snapshots
    // are legal (denied permission or a partial fix), and non-optional Doubles
    // trapped SwiftData decoding of payload-less location answers. See Plan 2
    // Task 4 fix — keep these optional.
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    public var horizontalAccuracy: Double?
    public var verticalAccuracy: Double?
    public var speed: Double?
    public var course: Double?
    public var timestamp: Date?
    public var placemark: Placemark?
    public init(latitude: Double? = nil, longitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct WeatherObservation: Codable, Hashable, Sendable {
    public var tempF: Double?
    public var tempC: Double?
    public var condition: String?
    public var relativeHumidity: String?
    public var windMPH: Double?
    public var windKPH: Double?
    public var windGustMPH: Double?
    public var windGustKPH: Double?
    public var windDirection: String?
    public var windDegrees: Double?
    public var pressureIn: Double?
    public var pressureMb: Double?
    public var visibilityMi: Double?
    public var visibilityKM: Double?
    public var feelslikeF: Double?
    public var feelslikeC: Double?
    public var dewpointC: Double?
    public var precipTodayIn: Double?
    public var precipTodayMetric: Double?
    public var uv: Double?
    public var stationID: String?
    public init() {}
}

public struct PhotoRecord: Codable, Hashable, Sendable {
    public var uniqueIdentifier: String
    public var assetUrl: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var dateTime: Date?
    public var latitude: Double?
    public var longitude: Double?
    public init(uniqueIdentifier: String) { self.uniqueIdentifier = uniqueIdentifier }
}

/// One captured health metric. `type` is an open string (e.g. "steps",
/// "flightsClimbed", "heartRateAvg") so new HealthKit types need no migration.
public struct HealthReading: Codable, Hashable, Sendable {
    public var type: String
    public var value: Double
    public var unit: String
    public var startDate: Date?
    public var endDate: Date?
    public init(type: String, value: Double, unit: String, startDate: Date? = nil, endDate: Date? = nil) {
        self.type = type
        self.value = value
        self.unit = unit
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct FocusState: Codable, Hashable, Sendable {
    public var label: String?
    public var isFocused: Bool
    public init(label: String? = nil, isFocused: Bool) {
        self.label = label
        self.isFocused = isFocused
    }
}

public struct TokenValue: Codable, Hashable, Sendable {
    public var uniqueIdentifier: String
    public var text: String
    public init(uniqueIdentifier: String = UUID().uuidString, text: String) {
        self.uniqueIdentifier = uniqueIdentifier
        self.text = text
    }
}

public struct LocationAnswer: Codable, Hashable, Sendable {
    public var text: String?
    public var foursquareVenueId: String?
    public var location: LocationSnapshot?
    public init() {}
}
