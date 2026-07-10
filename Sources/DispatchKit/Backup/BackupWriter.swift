import Foundation
import os

private let backupLog = Logger(subsystem: "io.robbie.Dispatch", category: "backup")

/// One backup destination's I/O pass (moved kit-side from BackupManager so
/// the path handling is testable with a temp-directory stand-in): ensure the
/// directory exists, write the new file atomically, prune per the kit-side
/// rotation arithmetic, and return how many backups remain.
///
/// Every filesystem call here is URL-based — never `URL.path()`-based. This
/// is load-bearing, not style (first-launch bug, plan 25 follow-up):
/// `URL.path()` percent-encodes by default, and the iCloud ubiquity
/// container lives under `…/Mobile Documents/…`, so the encoded path
/// (`Mobile%20Documents`) doesn't exist on disk. The old
/// `contentsOfDirectory(atPath: directory.path())` rotation listing
/// therefore threw NSCocoaErrorDomain 260 ("The folder Backups doesn't
/// exist") on every iCloud pass — after the backup file itself was written —
/// while the space-free local Documents path masked the bug locally.
public enum BackupWriter {
    /// Writes `data` as `filename` in `directory` (creating the directory
    /// and intermediates first), deletes rotation-expired backups, and
    /// returns the number of backup files remaining. Prune failures are
    /// logged and skipped — an undeletable old backup must not fail the
    /// fresh write that already succeeded.
    public static func writeAndRotate(data: Data, filename: String, in directory: URL,
                                      keep: Int = BackupRotation.defaultKeepCount) throws -> Int {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)

        // Rotation: kit-side arithmetic decides, this loop deletes. Backups
        // are our own write-once files, so a plain FileManager delete is
        // correct for the ubiquity directory too (no evict-then-delete).
        var existing = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ).map(\.lastPathComponent)
        for doomed in BackupRotation.filesToDelete(existing: existing, keep: keep) {
            do {
                try fileManager.removeItem(at: directory.appendingPathComponent(doomed))
                existing.removeAll { $0 == doomed }
            } catch {
                backupLog.error("failed to prune backup \(doomed, privacy: .public): \(error, privacy: .public)")
            }
        }
        let count = existing.filter { BackupRotation.date(fromFilename: $0) != nil }.count
        backupLog.info("wrote backup \(filename, privacy: .public) to \(directory.path(percentEncoded: false), privacy: .public) (\(count, privacy: .public) kept)")
        return count
    }
}
