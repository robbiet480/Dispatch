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
/// Plan 25 adds iCloud Drive as a destination (`BackupDestination`, default
/// Both): the same files, same rotation, additionally written to the
/// ubiquity container's `Documents/Backups/` — visible as iCloud Drive →
/// Dispatch → Backups via NSUbiquitousContainers. The ubiquity URL is
/// resolved ONCE off-main at init (the API is blocking/slow) and cached;
/// nil means iCloud is unavailable → local-only with a Settings status
/// line. Backups are write-once files with unique names, so no conflict
/// resolution is needed; rotation deletes via FileManager per destination.
/// A quota-full/failed iCloud write is logged and surfaced in Settings —
/// the local copy is unaffected.
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
    static let installIDKey = "backup.installID"

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL
    /// True when the test environment must skip all I/O; injecting a
    /// directory re-enables it (the unit-testable path).
    @ObservationIgnored private let isSkipped: Bool

    /// First-launch race guard inputs (kit-side decision — see
    /// BackupRotation.shouldDeferAutomaticBackup): when the on-disk store
    /// file was created (nil when unknown / in-memory) and whether the
    /// launched container is CloudKit-backed. A fresh-store + sync-enabled +
    /// never-synced launch must NOT auto-backup — the iPad first-launch bug
    /// wrote a "backup" with 7 seeded questions and ZERO reports because it
    /// ran before the initial CloudKit import finished. Manual "Back Up Now"
    /// is never gated by this.
    @ObservationIgnored private let storeCreatedAt: Date?
    @ObservationIgnored private let isSyncActive: Bool

    /// This device's backup-filename slug (model + persisted per-install
    /// short ID): multiple devices write into the SAME iCloud Drive folder,
    /// so filenames must be per-device and rotation scoped to this slug —
    /// otherwise two devices collide on a shared name and each device's
    /// rotation deletes the other's files.
    @ObservationIgnored private let deviceSlug: String

    /// iCloud Drive `Documents/Backups/` inside the ubiquity container —
    /// resolved once off-main at init and cached (plan 25); nil until
    /// resolution finishes or when iCloud is unavailable.
    @ObservationIgnored private var iCloudDirectory: URL?

    /// When the newest backup was written (defaults-persisted so staleness
    /// survives relaunch without listing the directory).
    private(set) var lastBackupDate: Date?
    /// How many backup files exist on disk (for the settings caption).
    private(set) var backupCount = 0
    private(set) var isBackingUp = false

    /// True while `deleteAllBackups()` is removing the Backups directories.
    ///
    /// Deletion releases the main actor for the whole removal, so without this
    /// a scene-active `backUpIfStale()` (or a "Back Up Now" tap) could land
    /// mid-deletion and WRITE a fresh backup after the directory was removed —
    /// silently resurrecting backups the user just asked to destroy, while the
    /// flow still reported success. Every backup entry point checks it.
    private(set) var isDeletingBackups = false
    /// Tri-state iCloud Drive availability for the Settings status line:
    /// nil while the off-main ubiquity resolution is still in flight.
    private(set) var iCloudAvailability: Bool?
    /// True when the most recent backup pass attempted an iCloud write and
    /// it failed (quota full, provider error) — surfaced in Settings; the
    /// local copy is unaffected.
    private(set) var lastICloudBackupFailed = false

    /// Default ON; the toggle lives in Settings → Data.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// Where backups go (plan 25). Defaults to `.both`; persisted raw value.
    var destination: BackupDestination {
        didSet { defaults.set(destination.rawValue, forKey: BackupDestination.defaultsKey) }
    }

    init(container: ModelContainer, defaults: UserDefaults, isTestEnvironment: Bool,
         directory: URL? = nil, iCloudDirectory: URL? = nil,
         storeCreatedAt: Date? = nil, isSyncActive: Bool = false) {
        self.container = container
        self.defaults = defaults
        self.storeCreatedAt = storeCreatedAt
        self.isSyncActive = isSyncActive
        isSkipped = isTestEnvironment && directory == nil
        self.directory = directory
            ?? URL.documentsDirectory.appendingPathComponent("Backups", isDirectory: true)
        // Per-install short ID (persisted): disambiguates two same-model
        // devices sharing an iCloud folder. 8 hex chars of a UUID is plenty.
        let installID: String
        if let stored = defaults.string(forKey: Self.installIDKey), !stored.isEmpty {
            installID = stored
        } else {
            installID = String(UUID().uuidString.prefix(8)).lowercased()
            defaults.set(installID, forKey: Self.installIDKey)
        }
        deviceSlug = BackupRotation.deviceSlug(model: DeviceIdentity.model, installID: installID)
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        destination = BackupDestination.stored(defaults.string(forKey: BackupDestination.defaultsKey))
        let stored = defaults.double(forKey: Self.lastBackupKey)
        lastBackupDate = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        if isTestEnvironment {
            // Tests never touch the real ubiquity API; an injected iCloud
            // directory stubs availability, absence stubs "unavailable".
            self.iCloudDirectory = iCloudDirectory
            iCloudAvailability = iCloudDirectory != nil
        } else {
            resolveICloudDirectoryAsync()
        }
        // Off the launch critical path (build-13 review minor): this init
        // runs inside DispatchApp.init, and the count is a Settings-caption
        // nicety — list the directory off-main and publish back.
        refreshCountAsync()
    }

    /// `url(forUbiquityContainerIdentifier:)` is documented as blocking (it
    /// can spin up the iCloud daemon) — resolve it exactly once off-main and
    /// publish the cached URL + availability back to the main actor.
    private func resolveICloudDirectoryAsync() {
        Task.detached(priority: .utility) {
            let url = FileManager.default.url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Backups", isDirectory: true)
            await MainActor.run {
                self.iCloudDirectory = url
                self.iCloudAvailability = url != nil
                if url == nil {
                    backupLog.info("iCloud Drive unavailable — backups stay local-only")
                }
            }
        }
    }

    /// Scene-active / report-save hook: backs up only when enabled and the
    /// newest backup is stale (>20h). Cheap when fresh — one Date compare.
    func backUpIfStale(now: Date = Date()) {
        guard !isSkipped, isEnabled, !isBackingUp, !isDeletingBackups,
              BackupRotation.isDue(lastBackupDate: lastBackupDate, now: now) else { return }
        // First-launch race guard (kit-side, tested): a fresh store with
        // sync enabled and no sync activity ever observed is plausibly
        // mid-initial-import — an auto-backup now would snapshot seeded
        // questions and zero reports. Retried on every scene-active; the
        // grace period bounds the deferral. backUpNow() skips this on
        // purpose: manual intent wins.
        if BackupRotation.shouldDeferAutomaticBackup(
            storeCreatedAt: storeCreatedAt, syncEnabled: isSyncActive,
            hasSyncedBefore: defaults.object(forKey: SyncDefaultsKeys.firstRemoteChange) != nil,
            now: now) {
            backupLog.info("automatic backup deferred: store is fresh and initial sync hasn't been observed yet")
            return
        }
        performBackup(now: now)
    }

    /// Settings "Back Up Now": ignores staleness (not the enabled toggle —
    /// the button sits under it and reads as part of the same feature, but
    /// a manual request is explicit consent, so honor it regardless).
    func backUpNow(now: Date = Date()) {
        guard !isSkipped, !isBackingUp, !isDeletingBackups else { return }
        performBackup(now: now)
    }

    private func performBackup(now: Date) {
        // Effective targets are decided kit-side (tested): local is the
        // guaranteed copy whenever iCloud can't be written.
        let iCloudAvailable = iCloudDirectory != nil
        let localTarget = destination.writesLocal(iCloudAvailable: iCloudAvailable) ? directory : nil
        let cloudTarget = destination.writesICloud(iCloudAvailable: iCloudAvailable) ? iCloudDirectory : nil
        guard localTarget != nil || cloudTarget != nil else { return }
        isBackingUp = true
        let container = container
        let slug = deviceSlug
        Task.detached(priority: .utility) {
            var result: (date: Date, count: Int)?
            var cloudFailed = false
            do {
                // Background ModelContext — same cross-context pattern as
                // import and the remote-change observer; the export never
                // touches the main actor.
                let data = try V2Exporter.exportData(from: ModelContext(container))
                let filename = BackupRotation.backupFilename(for: now, slug: slug)
                if let localTarget {
                    let count = try BackupWriter.writeAndRotate(
                        data: data, filename: filename, in: localTarget, slug: slug)
                    result = (now, count)
                }
                if let cloudTarget {
                    do {
                        let count = try BackupWriter.writeAndRotate(
                            data: data, filename: filename, in: cloudTarget, slug: slug)
                        // The caption's count comes from the local copy when
                        // both were written (they rotate identically).
                        if result == nil { result = (now, count) }
                    } catch {
                        // Quota-full or provider errors: logged + surfaced in
                        // Settings; the local copy is unaffected.
                        backupLog.error("iCloud backup failed: \(error, privacy: .public)")
                        cloudFailed = true
                    }
                }
            } catch {
                // Never user-blocking: log and move on; the next stale check
                // simply tries again.
                backupLog.error("backup failed: \(error, privacy: .public)")
                result = nil
            }
            await MainActor.run { [result, cloudFailed] in
                self.isBackingUp = false
                self.lastICloudBackupFailed = cloudFailed
                if let result {
                    self.lastBackupDate = result.date
                    self.defaults.set(result.date.timeIntervalSince1970, forKey: Self.lastBackupKey)
                    self.backupCount = result.count
                }
            }
        }
    }

    // The per-destination write/rotate pass moved kit-side (BackupWriter,
    // tested): its rotation listing MUST be URL-based, because `URL.path()`
    // percent-encodes and the ubiquity container path contains a space
    // (`Mobile Documents`) — the old atPath listing threw Cocoa error 260
    // ("The folder Backups doesn't exist") on every iCloud pass.

    /// Raised when "Also delete backups" could not remove everything. Carries a
    /// message rather than the underlying error so it can cross the actor
    /// boundary out of the detached deletion task.
    struct DeletionFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Delete All Data opt-in ("Also delete backups"): removes the whole
    /// Backups directory off-main and resets the staleness marker + caption
    /// state, so the next scene-active `backUpIfStale()` writes a fresh
    /// backup of the (reseeded) store. The enabled toggle is untouched —
    /// deleting data is not a request to stop backing up.
    ///
    /// AWAITABLE, and it throws. This used to be fire-and-forget with the
    /// filesystem errors swallowed into the log, so the delete-all flow put up
    /// "All Data Deleted" while the user's backups were, in fact, still on
    /// disk — the one outcome someone who ticks "also delete backups" would
    /// most want to know about. The caller now waits and reports the truth.
    func deleteAllBackups() async throws {
        guard !isSkipped else { return }

        // Close the door before opening the trapdoor: no new backup may start
        // while we delete, and an in-flight one must land BEFORE we remove the
        // directory — otherwise its write recreates what we just deleted.
        isDeletingBackups = true
        defer { isDeletingBackups = false }
        var waited = 0
        while isBackingUp && waited < 100 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }

        // "Also delete backups" means ALL of them. If the user targets iCloud
        // but the ubiquity container never resolved — signed out, iCloud Drive
        // off, or the resolve simply hasn't landed — then their iCloud backups
        // are full exports of the reports we are about to irreversibly wipe,
        // and we cannot touch them. Delete what we can reach, then SAY SO,
        // rather than reporting a clean slate we never achieved.
        let unreachableICloud = destination != .local && iCloudDirectory == nil
        let directories = [directory, iCloudDirectory].compactMap { $0 }
        let failure = await Task.detached(priority: .utility) { () -> String? in
            var firstFailure: String?
            for directory in directories {
                do {
                    // percentEncoded:false — the ubiquity path contains a
                    // space ("Mobile Documents"); the encoded default never
                    // matches, so iCloud backups would silently survive.
                    if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
                        try FileManager.default.removeItem(at: directory)
                    }
                } catch {
                    // Keep going: a failure on the iCloud copy must not strand
                    // the LOCAL backups the user also asked to delete.
                    backupLog.error("failed to delete backups: \(error, privacy: .public)")
                    firstFailure = firstFailure ?? error.localizedDescription
                }
            }
            return firstFailure
        }.value

        // These markers describe what is on disk — only clear them when the
        // disk agrees. If something survived, reconcile instead of claiming a
        // clean slate, and let the caller surface the failure.
        let problem = failure ?? (unreachableICloud
            ? "iCloud Drive is unavailable, so backups stored there were not removed."
            : nil)
        guard problem == nil else {
            refreshCountAsync()
            throw DeletionFailure(message: problem ?? "Unknown error")
        }
        backupLog.info("deleted all backups (delete-all-data opt-in)")
        lastBackupDate = nil
        backupCount = 0
        lastICloudBackupFailed = false
        defaults.removeObject(forKey: Self.lastBackupKey)
    }

    private func refreshCountAsync() {
        guard !isSkipped else { return }
        let directory = directory
        let slug = deviceSlug
        Task.detached(priority: .utility) {
            // URL-based listing (review minor): skips hidden files and
            // avoids the path-string round trip of the atPath variant.
            // Scoped to this device's slug — the caption counts OUR rotated
            // backups, matching what writeAndRotate returns.
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles)) ?? []
            let count = urls.count { BackupRotation.parse(filename: $0.lastPathComponent)?.slug == slug }
            await MainActor.run {
                self.backupCount = count
            }
        }
    }
}
