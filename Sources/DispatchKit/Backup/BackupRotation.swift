import Foundation

/// Pure arithmetic for the automatic backup rotation (plan 16): staleness
/// checks, deterministic filenames, and which files to prune. All decisions
/// live here (kit-side, tested); the app-side BackupManager only performs
/// I/O based on these answers.
public enum BackupRotation {
    /// Backups newer than this are "fresh enough" — 20h rather than 24h so a
    /// once-a-day usage pattern (e.g. 9am today vs 9:30am yesterday) still
    /// rolls a new backup every day instead of slipping later each day.
    public static let defaultThreshold: TimeInterval = 20 * 3600

    /// How many rotated backups to keep (newest first).
    public static let defaultKeepCount = 14

    static let filenamePrefix = "dispatch-backup-"
    static let filenameSuffix = ".json"

    /// True when a new backup should be written: never backed up, the last
    /// backup is at least `threshold` old, or the recorded date is in the
    /// future (clock rollback — treat the marker as untrustworthy).
    public static func isDue(lastBackupDate: Date?, now: Date,
                             threshold: TimeInterval = defaultThreshold) -> Bool {
        guard let lastBackupDate else { return true }
        if lastBackupDate > now { return true }
        return now.timeIntervalSince(lastBackupDate) >= threshold
    }

    /// Deterministic backup filename: `dispatch-backup-YYYY-MM-DD-HHmm.json`
    /// in the given time zone (local time, so filenames read naturally in
    /// the Files app). Lexicographic order == chronological order.
    public static func backupFilename(for date: Date, timeZone: TimeZone = .current) -> String {
        filenamePrefix + stampFormatter(timeZone: timeZone).string(from: date) + filenameSuffix
    }

    /// Inverse of `backupFilename(for:)`; nil for anything that isn't a
    /// well-formed backup filename. Minute precision (matches the encoding).
    public static func date(fromFilename filename: String, timeZone: TimeZone = .current) -> Date? {
        guard filename.hasPrefix(filenamePrefix), filename.hasSuffix(filenameSuffix) else { return nil }
        let stamp = String(filename.dropFirst(filenamePrefix.count).dropLast(filenameSuffix.count))
        return stampFormatter(timeZone: timeZone).date(from: stamp)
    }

    /// Which of `existing` should be deleted to keep only the newest `keep`
    /// backups. Ordering comes from the timestamp encoded in the filename
    /// (name as tiebreak). Files that don't parse as backup filenames are
    /// never returned — rotation must not delete a user's other documents.
    public static func filesToDelete(existing: [String], keep: Int = defaultKeepCount,
                                     timeZone: TimeZone = .current) -> [String] {
        let backups = existing
            .compactMap { name -> (name: String, date: Date)? in
                guard let date = date(fromFilename: name, timeZone: timeZone) else { return nil }
                return (name, date)
            }
            .sorted { ($0.date, $0.name) > ($1.date, $1.name) } // newest first
        guard keep >= 0, backups.count > keep else { return [] }
        return backups.dropFirst(keep).map(\.name)
    }

    /// `yyyy-MM-dd-HHmm` — fixed gregorian/POSIX so device locale settings
    /// (12/24h, non-gregorian calendars) can't change the wire format.
    private static func stampFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        return formatter
    }
}
