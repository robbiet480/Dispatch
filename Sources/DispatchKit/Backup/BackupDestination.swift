import Foundation

/// Where automatic backups are written (plan 25): the local Documents
/// directory (the guaranteed copy), the iCloud Drive "Dispatch" folder, or
/// both. Pure selection logic lives here (kit-side, tested); the app-side
/// `BackupManager` resolves the real ubiquity URL and performs the I/O.
public enum BackupDestination: String, CaseIterable, Sendable, Identifiable {
    case local
    case iCloudDrive = "icloud"
    case both

    /// Defaults key for the persisted raw value.
    public static let defaultsKey = "backup.destination"

    public var id: String { rawValue }

    /// Picker label.
    public var label: String {
        switch self {
        case .local: "On This Device"
        case .iCloudDrive: "iCloud Drive"
        case .both: "Both"
        }
    }

    /// Stored raw value → mode. Nothing stored (or an unknown value from a
    /// future build) defaults to `.both` — belt and braces: iCloud Drive when
    /// available, with the local copy always guaranteed.
    public static func stored(_ rawValue: String?) -> BackupDestination {
        rawValue.flatMap(BackupDestination.init(rawValue:)) ?? .both
    }

    /// Whether a backup pass should write the local copy. Local is the
    /// guaranteed destination: when iCloud Drive is unavailable (no account,
    /// iCloud Drive off, container unresolved), even the iCloud-only mode
    /// falls back to local rather than silently backing up nowhere.
    public func writesLocal(iCloudAvailable: Bool) -> Bool {
        switch self {
        case .local, .both: true
        case .iCloudDrive: !iCloudAvailable
        }
    }

    /// Whether a backup pass should write the iCloud Drive copy — only when
    /// the mode asks for it AND the ubiquity container resolved.
    public func writesICloud(iCloudAvailable: Bool) -> Bool {
        switch self {
        case .local: false
        case .iCloudDrive, .both: iCloudAvailable
        }
    }
}
