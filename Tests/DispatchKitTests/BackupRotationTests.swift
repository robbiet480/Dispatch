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

// MARK: - filename codec

@Test func backupFilenameIsDeterministicAndRoundTrips() throws {
    let stamp = date(2026, 7, 9, 14, 32)
    let name = BackupRotation.backupFilename(for: stamp, timeZone: utc)
    #expect(name == "dispatch-backup-2026-07-09-1432.json")
    let parsed = try #require(BackupRotation.date(fromFilename: name, timeZone: utc))
    #expect(parsed == stamp) // minute precision — exact round-trip
}

@Test func backupFilenameParserRejectsForeignFiles() {
    #expect(BackupRotation.date(fromFilename: "notes.json", timeZone: utc) == nil)
    #expect(BackupRotation.date(fromFilename: "dispatch-backup-garbage.json", timeZone: utc) == nil)
    #expect(BackupRotation.date(fromFilename: "dispatch-backup-2026-07-09-1432.txt", timeZone: utc) == nil)
    #expect(BackupRotation.date(fromFilename: "dispatch-backup-2026-99-99-9999.json", timeZone: utc) == nil)
}

// MARK: - rotation

@Test func rotationDeletesOldestBeyondKeepCount() {
    let names = (1...20).map {
        BackupRotation.backupFilename(for: date(2026, 6, $0, 9, 0), timeZone: utc)
    }
    let doomed = BackupRotation.filesToDelete(existing: names.shuffled(), keep: 14, timeZone: utc)
    // The oldest 6 go, newest first among the survivors untouched.
    #expect(Set(doomed) == Set(names.prefix(6)))
}

@Test func rotationKeepsEverythingAtOrUnderKeepCount() {
    let names = (1...14).map {
        BackupRotation.backupFilename(for: date(2026, 6, $0), timeZone: utc)
    }
    #expect(BackupRotation.filesToDelete(existing: names, keep: 14, timeZone: utc).isEmpty)
    #expect(BackupRotation.filesToDelete(existing: [], keep: 14, timeZone: utc).isEmpty)
}

@Test func rotationNeverTouchesForeignFiles() {
    var names = (1...20).map {
        BackupRotation.backupFilename(for: date(2026, 6, $0), timeZone: utc)
    }
    names.append("my-important-export.json")
    names.append(".DS_Store")
    let doomed = BackupRotation.filesToDelete(existing: names, keep: 14, timeZone: utc)
    #expect(doomed.count == 6)
    #expect(!doomed.contains("my-important-export.json"))
    #expect(!doomed.contains(".DS_Store"))
}

@Test func rotationOrderComesFromEncodedTimestampNotListOrder() {
    let old = BackupRotation.backupFilename(for: date(2026, 1, 1), timeZone: utc)
    let mid = BackupRotation.backupFilename(for: date(2026, 3, 1), timeZone: utc)
    let new = BackupRotation.backupFilename(for: date(2026, 7, 1), timeZone: utc)
    // Listed newest-first; keep 2 must still delete the chronologically oldest.
    #expect(BackupRotation.filesToDelete(existing: [new, mid, old], keep: 2, timeZone: utc) == [old])
    #expect(BackupRotation.filesToDelete(existing: [old, new, mid], keep: 1, timeZone: utc) == [mid, old])
}
