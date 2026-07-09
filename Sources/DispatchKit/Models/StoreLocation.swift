import Foundation

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
    }

    /// One-time move of `default.store` (+ `-wal`/`-shm` sidecars) from
    /// `legacy` into the App Group container. MUST run before any
    /// ModelContainer is constructed — same-volume FileManager moves, with
    /// rollback on partial failure so the store is never split across
    /// locations. CloudKit mirroring metadata lives inside the store and
    /// survives a path move.
    public static func migrate(from legacy: URL, to destination: URL,
                               fileManager: FileManager = .default) -> MigrationOutcome {
        if fileManager.fileExists(atPath: destination.path) { return .alreadyInPlace }
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
                for step in moved.reversed() {
                    try? fileManager.moveItem(at: step.target, to: step.source)
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
