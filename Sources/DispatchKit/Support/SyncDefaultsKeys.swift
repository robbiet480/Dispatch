import Foundation

/// Defaults keys written by the sync layer and read outside it.
///
/// `firstRemoteChange` lives here, rather than on `RemoteChangeObserver`, so
/// that readers do not have to depend on the observer itself. `BackupManager`
/// is the reader that matters: it consults the key to decide whether an
/// automatic backup should be deferred (a fresh store that has never seen a
/// remote change is plausibly mid-initial-import), and reaching into the
/// observer for one string was the only App-target dependency it had — which
/// kept it out of the hostless unit-test bundle, and so kept its deletion path
/// untested.
public enum SyncDefaultsKeys {
    /// Timestamp (`timeIntervalSince1970`) of the FIRST remote change CloudKit
    /// mirroring ever reported on this install. Absent = never synced.
    public static let firstRemoteChange = "sync.firstRemoteChangeDate"
}
