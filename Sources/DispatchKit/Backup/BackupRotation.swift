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

    /// How long after store creation the AUTOMATIC backup defers to initial
    /// CloudKit sync (first-launch race): a first-launch auto-backup that
    /// runs before the initial sync finishes snapshots a near-empty store
    /// (seeded questions, zero reports) — a uselessly misleading "backup".
    /// 30 minutes comfortably covers a normal initial import; after that we
    /// back up regardless (sync may simply be off/broken, and SOME backup
    /// beats none). Manual "Back Up Now" is never deferred — user intent wins.
    public static let initialSyncGracePeriod: TimeInterval = 30 * 60

    /// True when the AUTOMATIC backup should be skipped because the store is
    /// fresh and initial sync is plausibly still incomplete: the store was
    /// created within `grace` of `now` (or "created" in the future — clock
    /// rollback, age unknowable, stay safe), sync is enabled, and no
    /// successful sync activity has ever been observed. Any of: an old
    /// store, sync disabled, a prior sync marker, or an unknown creation
    /// date (nil — e.g. in-memory test stores) ⇒ proceed.
    public static func shouldDeferAutomaticBackup(storeCreatedAt: Date?, syncEnabled: Bool,
                                                  hasSyncedBefore: Bool, now: Date,
                                                  grace: TimeInterval = initialSyncGracePeriod) -> Bool {
        guard syncEnabled, !hasSyncedBefore, let storeCreatedAt else { return false }
        if storeCreatedAt > now { return true }
        return now.timeIntervalSince(storeCreatedAt) < grace
    }

    /// True when a new backup should be written: never backed up, the last
    /// backup is at least `threshold` old, or the recorded date is in the
    /// future (clock rollback — treat the marker as untrustworthy).
    public static func isDue(lastBackupDate: Date?, now: Date,
                             threshold: TimeInterval = defaultThreshold) -> Bool {
        guard let lastBackupDate else { return true }
        if lastBackupDate > now { return true }
        return now.timeIntervalSince(lastBackupDate) >= threshold
    }

    /// Filesystem-safe device slug for per-device backup filenames: the
    /// hardware model (e.g. "iPhone17,1") plus a persisted per-install short
    /// ID, so two same-model devices sharing an iCloud folder still get
    /// distinct slugs. Every non-alphanumeric run collapses to a single "-"
    /// (the "," in model identifiers, spaces, anything a filesystem or the
    /// stamp parser could trip on); nil/empty model falls back to "device".
    public static func deviceSlug(model: String?, installID: String) -> String {
        let modelPart = sanitize(model ?? "")
        let idPart = sanitize(installID)
        let base = modelPart.isEmpty ? "device" : modelPart
        return idPart.isEmpty ? base : "\(base)-\(idPart)"
    }

    private static func sanitize(_ raw: String) -> String {
        raw.split(whereSeparator: { !$0.isASCII || !($0.isLetter || $0.isNumber) })
            .joined(separator: "-")
    }

    /// Deterministic backup filename:
    /// `dispatch-backup-<slug>-YYYY-MM-DD-HHmm.json` in the given time zone
    /// (local time, so filenames read naturally in the Files app). The slug
    /// makes filenames per-device: multiple devices writing into the SAME
    /// iCloud Drive folder can no longer collide on a shared name, and
    /// rotation can scope deletion to this device's own files.
    /// Lexicographic order == chronological order within one device's files.
    public static func backupFilename(for date: Date, slug: String,
                                      timeZone: TimeZone = .current) -> String {
        filenamePrefix + slug + "-" + stampFormatter(timeZone: timeZone).string(from: date) + filenameSuffix
    }

    /// Decomposes a backup filename into its device slug and timestamp; nil
    /// for anything that isn't a well-formed backup filename. Legacy
    /// pre-slug files (`dispatch-backup-YYYY-MM-DD-HHmm.json`) parse with a
    /// nil slug. Minute precision (matches the encoding).
    public static func parse(filename: String, timeZone: TimeZone = .current)
        -> (slug: String?, date: Date)? {
        guard filename.hasPrefix(filenamePrefix), filename.hasSuffix(filenameSuffix) else { return nil }
        let body = String(filename.dropFirst(filenamePrefix.count).dropLast(filenameSuffix.count))
        let formatter = stampFormatter(timeZone: timeZone)
        // Strict stamp parse: DateFormatter is lenient (it accepts e.g. a
        // "-2026…" negative year), so require an exact re-encode round-trip.
        func strictDate(from stamp: String) -> Date? {
            guard let date = formatter.date(from: stamp),
                  formatter.string(from: date) == stamp else { return nil }
            return date
        }
        // Legacy shape: the whole body is the stamp.
        if let date = strictDate(from: body) {
            return (nil, date)
        }
        // Slugged shape: `<slug>-<15-char stamp>`.
        let stampLength = 15 // yyyy-MM-dd-HHmm
        guard body.count > stampLength + 1 else { return nil }
        let stamp = String(body.suffix(stampLength))
        let head = body.dropLast(stampLength)
        guard head.hasSuffix("-"), let date = strictDate(from: stamp) else {
            return nil
        }
        let slug = String(head.dropLast())
        return slug.isEmpty ? nil : (slug, date)
    }

    /// The timestamp encoded in a backup filename (slugged or legacy); nil
    /// for anything that isn't a well-formed backup filename.
    public static func date(fromFilename filename: String, timeZone: TimeZone = .current) -> Date? {
        parse(filename: filename, timeZone: timeZone)?.date
    }

    /// Which of `existing` should be deleted to keep only the newest `keep`
    /// backups WRITTEN BY THIS DEVICE (matching `slug`). Ordering comes from
    /// the timestamp encoded in the filename (name as tiebreak).
    ///
    /// Scoping is load-bearing: multiple devices rotate into the same shared
    /// iCloud folder, so deleting by age alone would let each device prune
    /// the others' files. Never returned, ever:
    /// - files that don't parse as backup filenames (a user's own documents),
    /// - another device's slugged backups,
    /// - legacy un-slugged `dispatch-backup-YYYY-MM-DD-HHmm.json` files —
    ///   grandfathered: their writer is unknowable, so no device may claim
    ///   (or delete) them automatically; users can clean them up by hand.
    public static func filesToDelete(existing: [String], slug: String,
                                     keep: Int = defaultKeepCount,
                                     timeZone: TimeZone = .current) -> [String] {
        let backups = existing
            .compactMap { name -> (name: String, date: Date)? in
                guard let parsed = parse(filename: name, timeZone: timeZone),
                      parsed.slug == slug else { return nil }
                return (name, parsed.date)
            }
            .sorted { ($0.date, $0.name) > ($1.date, $1.name) } // newest first
        guard keep >= 0, backups.count > keep else { return [] }
        return backups.dropFirst(keep).map(\.name)
    }

    /// Settings-footer line describing how many rotated backups exist.
    /// Nil when there are none: "0 backups kept (newest 14)." rendered
    /// alongside "No backups yet." read contradictory (visual review fix) —
    /// the empty state says nothing about retention. Populated phrasing is
    /// unchanged from the original caption.
    public static func retentionCaption(count: Int, keep: Int = defaultKeepCount) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 backup kept."
        default: "\(count) backups kept (newest \(keep))."
        }
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
