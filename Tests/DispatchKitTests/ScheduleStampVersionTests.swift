import Foundation
import Testing
@testable import DispatchKit

// The one-time versioned replan marker guarding the en_US_POSIX stamp pin
// (plan 17): must fire exactly once per install or pending prompts orphan
// on upgrade.

private func freshDefaults() -> UserDefaults {
    let suite = "stamp-version-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@Test func freshInstallNeedsMigrationReplanExactlyOnce() {
    let defaults = freshDefaults()
    // Fresh install / pre-pin upgrade: no stored version ⇒ due.
    #expect(ScheduleStampVersion.needsMigrationReplan(in: defaults))
    // Still due until explicitly marked (a crashed launch retries).
    #expect(ScheduleStampVersion.needsMigrationReplan(in: defaults))

    ScheduleStampVersion.markMigrated(in: defaults)
    #expect(!ScheduleStampVersion.needsMigrationReplan(in: defaults))
    #expect(defaults.integer(forKey: ScheduleStampVersion.defaultsKey)
        == ScheduleStampVersion.current)
}

@Test func olderStoredVersionIsDueAgainAfterBump() {
    let defaults = freshDefaults()
    // Simulate an install migrated at a hypothetical earlier version.
    defaults.set(ScheduleStampVersion.current - 1, forKey: ScheduleStampVersion.defaultsKey)
    #expect(ScheduleStampVersion.needsMigrationReplan(in: defaults))

    ScheduleStampVersion.markMigrated(in: defaults)
    #expect(!ScheduleStampVersion.needsMigrationReplan(in: defaults))
}

@Test func newerStoredVersionNeverRefires() {
    let defaults = freshDefaults()
    // Downgrade tolerance: a marker written by a newer build must not make
    // this build replan on every launch.
    defaults.set(ScheduleStampVersion.current + 5, forKey: ScheduleStampVersion.defaultsKey)
    #expect(!ScheduleStampVersion.needsMigrationReplan(in: defaults))
}
