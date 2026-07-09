import Foundation
import os

private let storeLog = Logger(subsystem: "io.robbie.Dispatch", category: "store-location")

/// Where the SwiftData store lives, shared by the app and the widget
/// extension (plan 14 amendment: the store moves into the App Group container
/// so widgets can query it directly with a read-only configuration).
public enum StoreLocation {
    public static let appGroupID = "group.io.robbie.Dispatch"
    public static let storeFilename = "default.store"
    /// SQLite sidecars that must travel with the main store file.
    static let sidecarSuffixes = ["-wal", "-shm"]

    /// The pre-plan-14 store URL — SwiftData's default ModelConfiguration
    /// location (Application Support/default.store inside the app sandbox).
    public static func legacyURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(storeFilename)
    }

    /// The shared store URL inside the App Group container; nil when the
    /// process lacks the App Group entitlement (misprovisioned build).
    public static func appGroupURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(storeFilename)
    }

    public enum MigrationOutcome: Equatable, Sendable {
        /// Store + sidecars moved to the App Group container.
        case migrated
        /// A store already exists at the destination — nothing to do.
        case alreadyInPlace
        /// No store at the legacy URL either — fresh install, create at the
        /// destination directly.
        case freshInstall
        /// Move failed (rolled back where possible); the caller MUST fall
        /// back to the legacy URL — never-fail-launch holds.
        case failed(String)
        /// A sidecar move failed AND rolling the already-moved main store
        /// back also failed. Failed FORWARD: remaining sidecars were force-
        /// moved (best effort) so the store and its WAL stay co-located at
        /// the destination — the alternative (store at destination, WAL
        /// orphaned at legacy) is silent data loss on the next open. The
        /// caller MUST use the destination URL and log loudly.
        case failedForward(String)
    }

    /// One-time move of `default.store` (+ `-wal`/`-shm` sidecars) from
    /// `legacy` into the App Group container. MUST run before any
    /// ModelContainer is constructed — same-volume FileManager moves, with
    /// rollback on partial failure so the store is never split across
    /// locations. CloudKit mirroring metadata lives inside the store and
    /// survives a path move.
    ///
    /// KNOWN RACE (accepted): the widget extension may run its
    /// `fileExists` + read-only open (SharedStoreReader) in the window
    /// between the main-store move landing and the sidecar moves. The
    /// window is a couple of same-volume renames during a single app
    /// launch's init, the widget only ever reads (it cannot corrupt the
    /// store), and a failed widget open just renders the placeholder until
    /// the next timeline reload. On a migration failure the rollback (or
    /// fail-forward) still leaves store+WAL co-located, and the app retries
    /// the migration on next launch — so no persistent bad state survives.
    public static func migrate(from legacy: URL, to destination: URL,
                               fileManager: FileManager = .default) -> MigrationOutcome {
        if fileManager.fileExists(atPath: destination.path) {
            // Leftover legacy sidecars next to an already-migrated store
            // mean a previous partial move (e.g. a fail-forward run that
            // could not move every sidecar); the destination store no longer
            // matches them, so they're stale — but their presence is worth
            // shouting about on every launch until someone looks.
            for suffix in sidecarSuffixes where fileManager.fileExists(atPath: legacy.path + suffix) {
                storeLog.error("LEFTOVER LEGACY SIDECAR at \(legacy.path + suffix, privacy: .public) — stale, store already migrated to destination")
            }
            return .alreadyInPlace
        }
        guard fileManager.fileExists(atPath: legacy.path) else { return .freshInstall }

        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
        } catch {
            return .failed("could not create destination directory: \(error)")
        }

        // Main store first, then sidecars; any failure rolls the moved files
        // back so the intact store stays at the legacy URL.
        let pairs: [(source: URL, target: URL)] = ([""] + sidecarSuffixes).map { suffix in
            (URL(fileURLWithPath: legacy.path + suffix),
             URL(fileURLWithPath: destination.path + suffix))
        }
        var moved: [(source: URL, target: URL)] = []
        for pair in pairs where fileManager.fileExists(atPath: pair.source.path) {
            do {
                try fileManager.moveItem(at: pair.source, to: pair.target)
                moved.append(pair)
            } catch {
                var rollbackErrors: [String] = []
                for step in moved.reversed() {
                    do {
                        try fileManager.moveItem(at: step.target, to: step.source)
                    } catch let rollbackError {
                        rollbackErrors.append("\(step.target.lastPathComponent): \(rollbackError)")
                    }
                }
                guard rollbackErrors.isEmpty else {
                    // Rollback ALSO failed — some of the store is stuck at
                    // the destination (typically the main store file). A
                    // half-rolled-back state where the next launch opens the
                    // destination store WITHOUT its WAL is silent data loss,
                    // so fail FORWARD: force-move everything still at the
                    // legacy URL (best effort, obstructions removed — the
                    // destination had no store, so anything in the way is
                    // orphaned garbage) to keep store + WAL co-located.
                    for remaining in pairs where fileManager.fileExists(atPath: remaining.source.path) {
                        if fileManager.fileExists(atPath: remaining.target.path) {
                            try? fileManager.removeItem(at: remaining.target)
                        }
                        do {
                            try fileManager.moveItem(at: remaining.source, to: remaining.target)
                        } catch let forwardError {
                            storeLog.error("FAIL-FORWARD move of \(remaining.source.lastPathComponent, privacy: .public) failed: \(forwardError, privacy: .public)")
                        }
                    }
                    return .failedForward(
                        "move of \(pair.source.lastPathComponent) failed (\(error)); "
                            + "rollback failed (\(rollbackErrors.joined(separator: "; "))); "
                            + "failed forward to keep store and WAL co-located at destination"
                    )
                }
                return .failed("move of \(pair.source.lastPathComponent) failed: \(error)")
            }
        }

        guard fileManager.fileExists(atPath: destination.path) else {
            return .failed("post-move verification failed: no store at destination")
        }
        return .migrated
    }
}
