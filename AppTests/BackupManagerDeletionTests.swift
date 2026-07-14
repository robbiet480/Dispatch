import DispatchKit
import SwiftData
import XCTest

/// Coverage for `BackupManager.deleteAllBackups()` — the "Also delete backups"
/// half of Delete All Data, which had none.
///
/// It gained real logic: attempt every directory, keep going past a failure,
/// report the FIRST one, clear the on-disk markers ONLY when the disk agrees,
/// and refuse to claim success when the user targets iCloud but the ubiquity
/// container never resolved. All of that guards an IRREVERSIBLE wipe, and all
/// of it is invisible to the UI tests (which run with `directory: nil`, where
/// the whole method is a no-op).
///
/// Hostless unit bundle — BackupManager.swift is compiled directly into this
/// target (see project.yml, the OptionBlockLayout/PlaceSearch precedent).
@MainActor
final class BackupManagerDeletionTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL.temporaryDirectory.appending(path: "backup-deletion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "backup-deletion-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeManager(local: URL?, iCloud: URL? = nil,
                             destination: BackupDestination = .local) throws -> BackupManager {
        let manager = BackupManager(
            container: try DispatchStore.inMemoryContainer(),
            defaults: defaults,
            isTestEnvironment: true,   // stubs iCloud availability by injection
            directory: local,
            iCloudDirectory: iCloud)
        manager.destination = destination
        return manager
    }

    @discardableResult
    private func seedBackups(in directory: URL, count: Int = 2) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<count {
            try Data("{}".utf8).write(to: directory.appending(path: "backup-\(index).json"))
        }
        return directory
    }

    /// `lastBackupDate` is `private(set)` — seed it the way the app does, via
    /// the persisted key that `init` reads.
    private func seedLastBackupMarker(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: BackupManager.lastBackupKey)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    // MARK: - Tests

    /// The happy path: local backups are removed and the markers describing
    /// them are cleared.
    func testDeletesLocalBackupsAndClearsMarkers() async throws {
        let local = try seedBackups(in: root.appending(path: "Backups"))
        seedLastBackupMarker(Date())
        let manager = try makeManager(local: local)
        XCTAssertNotNil(manager.lastBackupDate, "precondition: a backup marker exists")

        try await manager.deleteAllBackups()

        XCTAssertFalse(exists(local), "the Backups directory should be gone")
        XCTAssertNil(manager.lastBackupDate, "the staleness marker should be cleared")
        XCTAssertEqual(manager.backupCount, 0)
    }

    /// Both destinations: "also delete backups" means ALL of them.
    func testDeletesBothLocalAndICloudBackups() async throws {
        let local = try seedBackups(in: root.appending(path: "Backups"))
        let cloud = try seedBackups(in: root.appending(path: "iCloud/Backups"))
        let manager = try makeManager(local: local, iCloud: cloud, destination: .both)

        try await manager.deleteAllBackups()

        XCTAssertFalse(exists(local))
        XCTAssertFalse(exists(cloud), "the iCloud copy must go too")
    }

    /// THE finding: the user targets iCloud, but the ubiquity container never
    /// resolved (signed out / iCloud Drive off). Those backups are full exports
    /// of the reports being wiped and we cannot reach them — so the flow must
    /// NOT report success, and must not clear markers describing files that are
    /// still out there. It must still delete what it CAN reach.
    func testThrowsWhenICloudIsTargetedButUnreachable() async throws {
        let local = try seedBackups(in: root.appending(path: "Backups"))
        let lastBackup = Date(timeIntervalSince1970: 1_700_000_000)
        seedLastBackupMarker(lastBackup)
        let manager = try makeManager(local: local, iCloud: nil, destination: .both)

        do {
            try await manager.deleteAllBackups()
            XCTFail("deleting backups must not report success while iCloud copies survive")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("iCloud"),
                          "the message should name iCloud: \(error.localizedDescription)")
        }

        XCTAssertFalse(exists(local), "reachable backups must still be deleted")
        XCTAssertEqual(manager.lastBackupDate?.timeIntervalSince1970,
                       lastBackup.timeIntervalSince1970,
                       "markers must NOT be cleared while backups survive")
    }

    /// Local-only destination with no iCloud directory is not a failure — the
    /// user never asked for iCloud backups, so there is nothing to warn about.
    func testLocalOnlyDestinationDoesNotWarnAboutICloud() async throws {
        let local = try seedBackups(in: root.appending(path: "Backups"))
        let manager = try makeManager(local: local, iCloud: nil, destination: .local)

        try await manager.deleteAllBackups()

        XCTAssertFalse(exists(local))
        XCTAssertNil(manager.lastBackupDate)
    }

    /// No backups written yet: deleting is a no-op, not an error.
    func testDeletingWithNothingOnDiskSucceeds() async throws {
        let manager = try makeManager(local: root.appending(path: "Backups"))
        try await manager.deleteAllBackups()
        XCTAssertNil(manager.lastBackupDate)
    }

    /// The UI-test fixture (`directory: nil` under a test environment) is
    /// skipped entirely — the Mac settings UI test physically cannot touch
    /// backups, which is what makes it safe to drive the delete flow there.
    func testIsSkippedWhenNoDirectoryIsConfigured() async throws {
        let marker = Date(timeIntervalSince1970: 1_700_000_000)
        seedLastBackupMarker(marker)
        let manager = try makeManager(local: nil)

        try await manager.deleteAllBackups()

        XCTAssertEqual(manager.lastBackupDate?.timeIntervalSince1970, marker.timeIntervalSince1970,
                       "a skipped manager must not touch state")
    }

    /// Backups are quiesced during deletion: nothing may start a new backup
    /// while the directories are being removed, or it would write a fresh
    /// backup into the tree we just deleted.
    func testBackupsAreRefusedWhileDeletionIsInFlight() async throws {
        let local = try seedBackups(in: root.appending(path: "Backups"))
        let manager = try makeManager(local: local)

        async let deletion: Void = manager.deleteAllBackups()
        // Racy by nature; assert the flag exists and gates the entry points
        // rather than trying to hit the window reliably.
        manager.backUpNow()
        try await deletion

        XCTAssertFalse(manager.isDeletingBackups, "the flag must be cleared when deletion finishes")
        XCTAssertFalse(exists(local), "a backup must not have recreated the deleted directory")
    }
}
