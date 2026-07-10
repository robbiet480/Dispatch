import Foundation
import Testing
@testable import DispatchKit

// digestSchedules persistence + the one-time digestEnabled → schedules
// migration (plan 40). Follows the suite-named ephemeral-UserDefaults pattern.

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "np-digest-\(UUID().uuidString)")!
}

@Test func digestSchedulesDefaultsToEmpty() {
    let prefs = NotificationPrefs(defaults: freshDefaults())
    #expect(prefs.digestSchedules.isEmpty)
}

@Test func digestSchedulesRoundTripThroughDefaults() {
    let defaults = freshDefaults()
    let schedules = [
        DigestSchedule(id: UUID(), cadence: .weekly(weekday: 1),
                       hour: 19, minute: 0, isEnabled: true),
        DigestSchedule(id: UUID(), cadence: .monthly(dayOfMonth: 31),
                       hour: 9, minute: 30, isEnabled: false),
    ]
    NotificationPrefs(defaults: defaults).digestSchedules = schedules
    #expect(NotificationPrefs(defaults: defaults).digestSchedules == schedules)
}

@Test func digestSchedulesRoundTripEmptyArray() {
    let defaults = freshDefaults()
    NotificationPrefs(defaults: defaults).digestSchedules = []
    #expect(NotificationPrefs(defaults: defaults).digestSchedules == [])
    // Writing (even empty) leaves the key present — the migration marker.
    #expect(defaults.data(forKey: "digestSchedules") != nil)
}

@Test func migrationSeedsWeeklySundayWhenDigestWasEnabled() {
    let defaults = freshDefaults()
    defaults.set(true, forKey: "digestEnabled")
    let prefs = NotificationPrefs(defaults: defaults)
    prefs.migrateDigestSchedulesIfNeeded()

    let schedules = prefs.digestSchedules
    #expect(schedules.count == 1)
    #expect(schedules.first?.cadence == .weekly(weekday: 1))
    #expect(schedules.first?.hour == 19)
    #expect(schedules.first?.minute == 0)
    #expect(schedules.first?.isEnabled == true)
}

@Test func migrationSeedsEmptyWhenDigestWasDisabled() {
    let defaults = freshDefaults()
    // digestEnabled absent → false.
    let prefs = NotificationPrefs(defaults: defaults)
    prefs.migrateDigestSchedulesIfNeeded()
    #expect(prefs.digestSchedules.isEmpty)
    #expect(defaults.data(forKey: "digestSchedules") != nil)
}

@Test func digestMigrationIsIdempotent() {
    let defaults = freshDefaults()
    defaults.set(true, forKey: "digestEnabled")
    let prefs = NotificationPrefs(defaults: defaults)
    prefs.migrateDigestSchedulesIfNeeded()

    // A later user edit must survive a second migration call.
    let edited = [DigestSchedule(id: UUID(), cadence: .monthly(dayOfMonth: 15),
                                 hour: 8, minute: 0, isEnabled: true)]
    prefs.digestSchedules = edited
    prefs.migrateDigestSchedulesIfNeeded()
    #expect(prefs.digestSchedules == edited)
}
