import DispatchKit
import Foundation
import Observation
import os
import SwiftData

private let backupLog = Logger(subsystem: "io.robbie.Dispatch", category: "backup")

/// Automatic rotating backups (plan 16): full v2 exports written to
/// `Documents/Backups/dispatch-backup-YYYY-MM-DD-HHmm.json`, newest 14 kept.
/// Documents is user-visible in the Files app ("On My iPhone → Dispatch")
/// and Finder via the UIFileSharingEnabled/LSSupportsOpeningDocumentsInPlace
/// Info.plist keys — plain plist keys, no entitlement (plan-16 hard
/// constraint), no BGTaskScheduler.
///
/// Scheduling is foreground-only and never user-blocking: scene-active and
/// report-save call `backUpIfStale()` (the 20h staleness check IS the
/// debounce — at most one backup a day in normal use), and the export runs
/// off-main on a background `ModelContext(container)` (the import/
/// remote-change pattern). All rotation arithmetic lives kit-side in
/// `BackupRotation` (tested); this class only performs the I/O. Failures
/// are logged to the `backup` OSLog category and surface nowhere else.
///
/// Test environments skip everything — except when a directory is injected,
/// the unit-testable path, which runs regardless.
@MainActor
@Observable
final class BackupManager {
    static let enabledKey = "backup.enabled"
    static let lastBackupKey = "backup.lastBackupDate"

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL
    /// True when the test environment must skip all I/O; injecting a
    /// directory re-enables it (the unit-testable path).
    @ObservationIgnored private let isSkipped: Bool

    /// When the newest backup was written (defaults-persisted so staleness
    /// survives relaunch without listing the directory).
    private(set) var lastBackupDate: Date?
    /// How many backup files exist on disk (for the settings caption).
    private(set) var backupCount = 0
    private(set) var isBackingUp = false

    /// Default ON; the toggle lives in Settings → Data.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    init(container: ModelContainer, defaults: UserDefaults, isTestEnvironment: Bool,
         directory: URL? = nil) {
        self.container = container
        self.defaults = defaults
        isSkipped = isTestEnvironment && directory == nil
        self.directory = directory
            ?? URL.documentsDirectory.appendingPathComponent("Backups", isDirectory: true)
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        let stored = defaults.double(forKey: Self.lastBackupKey)
        lastBackupDate = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        // Off the launch critical path (build-13 review minor): this init
        // runs inside DispatchApp.init, and the count is a Settings-caption
        // nicety — list the directory off-main and publish back.
        refreshCountAsync()
    }

    /// Scene-active / report-save hook: backs up only when enabled and the
    /// newest backup is stale (>20h). Cheap when fresh — one Date compare.
    func backUpIfStale(now: Date = Date()) {
        guard !isSkipped, isEnabled, !isBackingUp,
              BackupRotation.isDue(lastBackupDate: lastBackupDate, now: now) else { return }
        performBackup(now: now)
    }

    /// Settings "Back Up Now": ignores staleness (not the enabled toggle —
    /// the button sits under it and reads as part of the same feature, but
    /// a manual request is explicit consent, so honor it regardless).
    func backUpNow(now: Date = Date()) {
        guard !isSkipped, !isBackingUp else { return }
        performBackup(now: now)
    }

    private func performBackup(now: Date) {
        isBackingUp = true
        let container = container
        let directory = directory
        Task.detached(priority: .utility) {
            let result: (date: Date, count: Int)?
            do {
                // Background ModelContext — same cross-context pattern as
                // import and the remote-change observer; the export never
                // touches the main actor.
                let data = try V2Exporter.exportData(from: ModelContext(container))
                let fileManager = FileManager.default
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let filename = BackupRotation.backupFilename(for: now)
                try data.write(to: directory.appendingPathComponent(filename), options: .atomic)

                // Rotation: kit-side arithmetic decides, this loop deletes.
                var existing = try fileManager.contentsOfDirectory(atPath: directory.path())
                for doomed in BackupRotation.filesToDelete(existing: existing) {
                    do {
                        try fileManager.removeItem(at: directory.appendingPathComponent(doomed))
                        existing.removeAll { $0 == doomed }
                    } catch {
                        backupLog.error("failed to prune backup \(doomed, privacy: .public): \(error, privacy: .public)")
                    }
                }
                let count = existing.filter { BackupRotation.date(fromFilename: $0) != nil }.count
                backupLog.info("wrote backup \(filename, privacy: .public) (\(count, privacy: .public) kept)")
                result = (now, count)
            } catch {
                // Never user-blocking: log and move on; the next stale check
                // simply tries again.
                backupLog.error("backup failed: \(error, privacy: .public)")
                result = nil
            }
            await MainActor.run { [result] in
                self.isBackingUp = false
                if let result {
                    self.lastBackupDate = result.date
                    self.defaults.set(result.date.timeIntervalSince1970, forKey: Self.lastBackupKey)
                    self.backupCount = result.count
                }
            }
        }
    }

    private func refreshCountAsync() {
        guard !isSkipped else { return }
        let directory = directory
        Task.detached(priority: .utility) {
            // URL-based listing (review minor): skips hidden files and
            // avoids the path-string round trip of the atPath variant.
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles)) ?? []
            let count = urls.count { BackupRotation.date(fromFilename: $0.lastPathComponent) != nil }
            await MainActor.run {
                self.backupCount = count
            }
        }
    }
}
