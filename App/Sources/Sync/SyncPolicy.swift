import Foundation
import os

/// One OSLog category for every sync decision — enabled, disabled, fallback,
/// and the reason — so `log stream --predicate 'category == "sync"'` tells
/// the whole story of why the store is (or isn't) mirroring to CloudKit.
let syncLog = Logger(subsystem: "io.robbie.Dispatch", category: "sync")

/// Decides whether the SwiftData store attaches CloudKit mirroring at launch.
///
/// The toggle persists to the app defaults suite and is read once at
/// container construction — switching the live ModelContainer between
/// local-only and CloudKit mid-flight would mean swapping the store under
/// live views, so the toggle deliberately has relaunch semantics (the
/// Settings UI says "Takes effect after reopening Dispatch").
///
/// Test isolation is absolute: `--ui-testing`/`--mock-sensors` (and any
/// other path that flags the test environment) always resolves to a local,
/// non-CloudKit container regardless of the stored preference.
struct SyncPolicy {
    /// Defaults key for the user's toggle. Default ON: sync is the expected
    /// behavior for new installs, and existing installs adopt ON at upgrade
    /// (export remains the manual escape hatch).
    static let enabledKey = "iCloudSyncEnabled"

    /// The private CloudKit container backing SwiftData mirroring.
    static let containerIdentifier = "iCloud.io.robbie.Dispatch"

    private let defaults: UserDefaults
    private let isTestEnvironment: Bool

    init(defaults: UserDefaults, isTestEnvironment: Bool) {
        self.defaults = defaults
        self.isTestEnvironment = isTestEnvironment
    }

    /// The user's stored preference; absent key means ON.
    var userPreference: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// The effective decision for this launch. Logs the reason either way.
    var shouldSync: Bool {
        if isTestEnvironment {
            syncLog.info("sync disabled: test environment (forced local container)")
            return false
        }
        if !userPreference {
            syncLog.info("sync disabled: user toggle off")
            return false
        }
        syncLog.info("sync enabled: user toggle on (or default)")
        return true
    }
}
