import Foundation

/// Version marker for the scheduler's content-addressed identifier stamps
/// (`prompt-<yyyyMMdd-HHmm>`, `gprompt-<groupID>-<stamp>`, nag siblings).
///
/// The stamp formatter is pinned to `en_US_POSIX` as of version 2 (plan 17
/// hygiene): unpinned, a device set to a locale with non-ASCII numerals
/// (e.g. Arabic) rendered different stamp strings, so identifiers for the
/// SAME planned minute differed across locale changes and — worse — differed
/// from what the parsing helpers expect, orphaning pending prompts and nag
/// chains. Pinning fixes it going forward, but requests scheduled by an
/// older build carry old-format stamps, so the app must run ONE full replan
/// after upgrading (the replan removes by prefix — locale-independent — and
/// re-adds everything with pinned stamps).
///
/// This marker makes that replan fire exactly once per install: version 0
/// (fresh install or pre-pin upgrade) < 2 ⇒ due; `markMigrated` records the
/// current version. Bump `current` if the stamp encoding ever changes again.
public enum ScheduleStampVersion {
    /// 2 = en_US_POSIX-pinned stamps. (1 is reserved for the unpinned
    /// format so a future downgrade-then-upgrade can't alias with 0.)
    public static let current = 2
    public static let defaultsKey = "scheduleStampFormatVersion"

    /// True when the persisted stamp version predates `current` — the
    /// caller must run a full replan and then `markMigrated`.
    public static func needsMigrationReplan(in defaults: UserDefaults) -> Bool {
        defaults.integer(forKey: defaultsKey) < current
    }

    public static func markMigrated(in defaults: UserDefaults) {
        defaults.set(current, forKey: defaultsKey)
    }
}
