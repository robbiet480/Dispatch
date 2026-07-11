import Foundation
import Testing
@testable import DispatchKit

private let utc = TimeZone(identifier: "UTC")!

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute))!
}

// MARK: - isDue

@Test func backupIsDueWhenNeverBackedUp() {
    #expect(BackupRotation.isDue(lastBackupDate: nil, now: date(2026, 7, 9)))
}

@Test func backupDueBoundaries() {
    let now = date(2026, 7, 9, 12, 0)
    // Just under 20h → not due.
    #expect(!BackupRotation.isDue(lastBackupDate: now.addingTimeInterval(-20 * 3600 + 1), now: now))
    // Exactly 20h → due (inclusive threshold).
    #expect(BackupRotation.isDue(lastBackupDate: now.addingTimeInterval(-20 * 3600), now: now))
    // Well past → due.
    #expect(BackupRotation.isDue(lastBackupDate: now.addingTimeInterval(-48 * 3600), now: now))
    // Fresh → not due.
    #expect(!BackupRotation.isDue(lastBackupDate: now.addingTimeInterval(-60), now: now))
}

@Test func backupDueWhenLastDateIsInTheFuture() {
    // Clock rolled back: the persisted marker is ahead of now — treat as due
    // rather than silently never backing up until the clock catches up.
    let now = date(2026, 7, 9, 12, 0)
    #expect(BackupRotation.isDue(lastBackupDate: now.addingTimeInterval(3600), now: now))
}

@Test func backupDueHonorsCustomThreshold() {
    let now = date(2026, 7, 9, 12, 0)
    #expect(BackupRotation.isDue(lastBackupDate: now.addingTimeInterval(-120), now: now, threshold: 60))
    #expect(!BackupRotation.isDue(lastBackupDate: now.addingTimeInterval(-30), now: now, threshold: 60))
}

// MARK: - device slug

private let slug = "iPhone17-1-ab12cd34"

@Test func deviceSlugIsFilesystemSafeAndStable() {
    // The "," in hardware model identifiers must not reach a filename.
    #expect(BackupRotation.deviceSlug(model: "iPhone17,1", installID: "ab12cd34") == "iPhone17-1-ab12cd34")
    #expect(BackupRotation.deviceSlug(model: "Watch7,4", installID: "ff00aa11") == "Watch7-4-ff00aa11")
    // Anything hostile collapses to dashes; nil/empty model falls back.
    #expect(BackupRotation.deviceSlug(model: "a/b\\c:d e", installID: "x") == "a-b-c-d-e-x")
    #expect(BackupRotation.deviceSlug(model: nil, installID: "ab12cd34") == "device-ab12cd34")
    #expect(BackupRotation.deviceSlug(model: "", installID: "ab12cd34") == "device-ab12cd34")
}

// MARK: - filename codec

@Test func backupFilenameIsDeterministicAndRoundTrips() throws {
    let stamp = date(2026, 7, 9, 14, 32)
    let name = BackupRotation.backupFilename(for: stamp, slug: slug, timeZone: utc)
    #expect(name == "dispatch-backup-iPhone17-1-ab12cd34-2026-07-09-1432.json")
    let parsed = try #require(BackupRotation.parse(filename: name, timeZone: utc))
    #expect(parsed.date == stamp) // minute precision — exact round-trip
    #expect(parsed.slug == slug)
    #expect(BackupRotation.date(fromFilename: name, timeZone: utc) == stamp)
}

@Test func backupFilenameParserAcceptsLegacyUnsluggedFiles() throws {
    // Pre-slug shape (already on users' disks/iCloud): parses with nil slug.
    let parsed = try #require(BackupRotation.parse(
        filename: "dispatch-backup-2026-07-09-1432.json", timeZone: utc))
    #expect(parsed.slug == nil)
    #expect(parsed.date == date(2026, 7, 9, 14, 32))
}

@Test func backupFilenameParserRejectsForeignFiles() {
    #expect(BackupRotation.date(fromFilename: "notes.json", timeZone: utc) == nil)
    #expect(BackupRotation.date(fromFilename: "dispatch-backup-garbage.json", timeZone: utc) == nil)
    #expect(BackupRotation.date(fromFilename: "dispatch-backup-2026-07-09-1432.txt", timeZone: utc) == nil)
    #expect(BackupRotation.date(fromFilename: "dispatch-backup-2026-99-99-9999.json", timeZone: utc) == nil)
    #expect(BackupRotation.date(fromFilename: "dispatch-backup-slug-2026-99-99-9999.json", timeZone: utc) == nil)
    #expect(BackupRotation.date(fromFilename: "dispatch-backup--2026-07-09-1432.json", timeZone: utc) == nil)
}

// MARK: - rotation

@Test func rotationDeletesOldestBeyondKeepCount() {
    let names = (1...20).map {
        BackupRotation.backupFilename(for: date(2026, 6, $0, 9, 0), slug: slug, timeZone: utc)
    }
    let doomed = BackupRotation.filesToDelete(existing: names.shuffled(), slug: slug, keep: 14, timeZone: utc)
    // The oldest 6 go, newest first among the survivors untouched.
    #expect(Set(doomed) == Set(names.prefix(6)))
}

@Test func rotationKeepsEverythingAtOrUnderKeepCount() {
    let names = (1...14).map {
        BackupRotation.backupFilename(for: date(2026, 6, $0), slug: slug, timeZone: utc)
    }
    #expect(BackupRotation.filesToDelete(existing: names, slug: slug, keep: 14, timeZone: utc).isEmpty)
    #expect(BackupRotation.filesToDelete(existing: [], slug: slug, keep: 14, timeZone: utc).isEmpty)
}

@Test func rotationNeverTouchesForeignFiles() {
    var names = (1...20).map {
        BackupRotation.backupFilename(for: date(2026, 6, $0), slug: slug, timeZone: utc)
    }
    names.append("my-important-export.json")
    names.append(".DS_Store")
    let doomed = BackupRotation.filesToDelete(existing: names, slug: slug, keep: 14, timeZone: utc)
    #expect(doomed.count == 6)
    #expect(!doomed.contains("my-important-export.json"))
    #expect(!doomed.contains(".DS_Store"))
}

@Test func rotationOrderComesFromEncodedTimestampNotListOrder() {
    let old = BackupRotation.backupFilename(for: date(2026, 1, 1), slug: slug, timeZone: utc)
    let mid = BackupRotation.backupFilename(for: date(2026, 3, 1), slug: slug, timeZone: utc)
    let new = BackupRotation.backupFilename(for: date(2026, 7, 1), slug: slug, timeZone: utc)
    // Listed newest-first; keep 2 must still delete the chronologically oldest.
    #expect(BackupRotation.filesToDelete(existing: [new, mid, old], slug: slug, keep: 2, timeZone: utc) == [old])
    #expect(BackupRotation.filesToDelete(existing: [old, new, mid], slug: slug, keep: 1, timeZone: utc) == [mid, old])
}

/// The shared-iCloud-folder scenario: two devices' slugged backups plus a
/// user's legacy un-slugged files in ONE directory. Rotation for one device
/// must only ever delete that device's own files — the other device's
/// backups and the grandfathered legacy files are untouchable, even when
/// they are the chronologically oldest files present.
@Test func rotationScopesToThisDeviceSlugOnly() {
    let mine = "iPhone17-1-ab12cd34"
    let theirs = "iPad16-3-99ee00ff"
    // Their files and the legacy files are OLDER than all of mine.
    let theirNames = (1...5).map {
        BackupRotation.backupFilename(for: date(2025, 1, $0), slug: theirs, timeZone: utc)
    }
    let legacyNames = ["dispatch-backup-2024-12-01-0900.json",
                       "dispatch-backup-2024-12-02-0900.json"]
    let myNames = (1...5).map {
        BackupRotation.backupFilename(for: date(2026, 6, $0), slug: mine, timeZone: utc)
    }
    let existing = (theirNames + legacyNames + myNames).shuffled()

    // keep 3 of MINE: only my two oldest go.
    let doomed = BackupRotation.filesToDelete(existing: existing, slug: mine, keep: 3, timeZone: utc)
    #expect(Set(doomed) == Set(myNames.prefix(2)))

    // Even keep 0 can only ever claim my own files.
    let scorchedEarth = BackupRotation.filesToDelete(existing: existing, slug: mine, keep: 0, timeZone: utc)
    #expect(Set(scorchedEarth) == Set(myNames))
    #expect(scorchedEarth.allSatisfy { !theirNames.contains($0) && !legacyNames.contains($0) })
}

// MARK: - first-launch auto-backup guard

/// The iPad first-launch bug: the auto-backup ran before initial CloudKit
/// sync pulled any reports, snapshotting 7 seeded questions and zero
/// reports. The guard defers the AUTOMATIC backup while the store is fresh,
/// sync is enabled, and no sync activity has ever been observed.
@Test func autoBackupDefersOnlyForFreshSyncingNeverSyncedStores() {
    let now = date(2026, 7, 10, 12, 0)
    let fresh = now.addingTimeInterval(-5 * 60) // 5 min old store
    let old = now.addingTimeInterval(-2 * 24 * 3600)

    // The bug scenario: defer.
    #expect(BackupRotation.shouldDeferAutomaticBackup(
        storeCreatedAt: fresh, syncEnabled: true, hasSyncedBefore: false, now: now))

    // Any leg missing ⇒ proceed.
    #expect(!BackupRotation.shouldDeferAutomaticBackup(
        storeCreatedAt: old, syncEnabled: true, hasSyncedBefore: false, now: now))
    #expect(!BackupRotation.shouldDeferAutomaticBackup(
        storeCreatedAt: fresh, syncEnabled: false, hasSyncedBefore: false, now: now))
    #expect(!BackupRotation.shouldDeferAutomaticBackup(
        storeCreatedAt: fresh, syncEnabled: true, hasSyncedBefore: true, now: now))
    // Unknown creation date (in-memory stores, attribute lookup failure).
    #expect(!BackupRotation.shouldDeferAutomaticBackup(
        storeCreatedAt: nil, syncEnabled: true, hasSyncedBefore: false, now: now))
}

@Test func autoBackupGuardBoundaries() {
    let now = date(2026, 7, 10, 12, 0)
    // Just inside the 30-minute grace ⇒ defer; exactly at it ⇒ proceed.
    #expect(BackupRotation.shouldDeferAutomaticBackup(
        storeCreatedAt: now.addingTimeInterval(-30 * 60 + 1), syncEnabled: true,
        hasSyncedBefore: false, now: now))
    #expect(!BackupRotation.shouldDeferAutomaticBackup(
        storeCreatedAt: now.addingTimeInterval(-30 * 60), syncEnabled: true,
        hasSyncedBefore: false, now: now))
    // "Created in the future" (clock rollback): age unknowable — stay safe
    // and defer; the manual path remains available and the clock catches up.
    #expect(BackupRotation.shouldDeferAutomaticBackup(
        storeCreatedAt: now.addingTimeInterval(3600), syncEnabled: true,
        hasSyncedBefore: false, now: now))
    // Custom grace is honored.
    #expect(!BackupRotation.shouldDeferAutomaticBackup(
        storeCreatedAt: now.addingTimeInterval(-120), syncEnabled: true,
        hasSyncedBefore: false, now: now, grace: 60))
}

// MARK: - Retention caption (review fix)

@Test func retentionCaptionIsNilWithZeroBackups() {
    // "No backups yet. 0 backups kept (newest 14)." was contradictory —
    // the empty state must say nothing about retention.
    #expect(BackupRotation.retentionCaption(count: 0) == nil)
    #expect(BackupRotation.retentionCaption(count: -1) == nil)
}

@Test func retentionCaptionKeepsPopulatedPhrasing() {
    #expect(BackupRotation.retentionCaption(count: 1) == "1 backup kept.")
    #expect(BackupRotation.retentionCaption(count: 3) == "3 backups kept (newest 14).")
    #expect(BackupRotation.retentionCaption(count: 14) == "14 backups kept (newest 14).")
    #expect(BackupRotation.retentionCaption(count: 3, keep: 5) == "3 backups kept (newest 5).")
}
