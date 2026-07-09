import Foundation
import Testing
@testable import DispatchKit

private func makeSandbox() throws -> (legacy: URL, destination: URL, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("store-migration-\(UUID().uuidString)")
    let legacyDir = root.appendingPathComponent("legacy")
    let groupDir = root.appendingPathComponent("group")
    try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    return (legacyDir.appendingPathComponent(StoreLocation.storeFilename),
            groupDir.appendingPathComponent(StoreLocation.storeFilename),
            root)
}

private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
}

private func exists(_ url: URL, suffix: String = "") -> Bool {
    FileManager.default.fileExists(atPath: url.path + suffix)
}

@Test func migrateMovesStoreAndSidecars() throws {
    let (legacy, destination, root) = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("store", to: legacy)
    try write("wal", to: URL(fileURLWithPath: legacy.path + "-wal"))
    try write("shm", to: URL(fileURLWithPath: legacy.path + "-shm"))

    let outcome = StoreLocation.migrate(from: legacy, to: destination)

    #expect(outcome == .migrated)
    for suffix in ["", "-wal", "-shm"] {
        #expect(exists(destination, suffix: suffix), "missing \(suffix) at destination")
        #expect(!exists(legacy, suffix: suffix), "\(suffix) left behind at legacy URL")
    }
    // Content survived the move.
    #expect(try String(contentsOf: destination, encoding: .utf8) == "store")
}

@Test func migrateToleratesMissingSidecars() throws {
    let (legacy, destination, root) = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("store", to: legacy)

    #expect(StoreLocation.migrate(from: legacy, to: destination) == .migrated)
    #expect(exists(destination))
    #expect(!exists(destination, suffix: "-wal"))
}

@Test func migrateFreshInstallIsNoOp() throws {
    let (legacy, destination, root) = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(StoreLocation.migrate(from: legacy, to: destination) == .freshInstall)
    #expect(!exists(destination))
}

@Test func migrateIsIdempotentOnceStoreIsAtDestination() throws {
    let (legacy, destination, root) = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("store", to: legacy)

    #expect(StoreLocation.migrate(from: legacy, to: destination) == .migrated)
    #expect(StoreLocation.migrate(from: legacy, to: destination) == .alreadyInPlace)
}

@Test func migrateLeavesLegacyUntouchedWhenDestinationAlreadyExists() throws {
    let (legacy, destination, root) = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try write("existing", to: destination)
    try write("legacy-store", to: legacy)

    #expect(StoreLocation.migrate(from: legacy, to: destination) == .alreadyInPlace)
    #expect(try String(contentsOf: legacy, encoding: .utf8) == "legacy-store")
    #expect(try String(contentsOf: destination, encoding: .utf8) == "existing")
}

/// FileManager that throws for moves whose SOURCE path is in `failingMoves`
/// — lets tests sabotage a specific forward move and/or a specific rollback
/// move deterministically.
private final class SabotagingFileManager: FileManager, @unchecked Sendable {
    let failingMoves: Set<String>

    init(failingMoves: Set<String>) {
        self.failingMoves = failingMoves
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if failingMoves.contains(srcURL.path) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

@Test func migrateFailureRollsBackAndReportsFailed() throws {
    let (legacy, destination, root) = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("store", to: legacy)
    try write("wal", to: URL(fileURLWithPath: legacy.path + "-wal"))
    // Sabotage: a DIRECTORY where the -wal file must land makes that move
    // fail after the main store already moved — rollback must restore it.
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: destination.path + "-wal"), withIntermediateDirectories: true
    )

    let outcome = StoreLocation.migrate(from: legacy, to: destination)

    guard case .failed = outcome else {
        Issue.record("expected .failed, got \(outcome)")
        return
    }
    #expect(exists(legacy), "main store not rolled back to legacy URL")
    #expect(exists(legacy, suffix: "-wal"))
    #expect(!exists(destination), "main store left at destination after failure")
}

@Test func migrateSabotagedRollbackFailsForwardKeepingStoreAndWALCoLocated() throws {
    let (legacy, destination, root) = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("store", to: legacy)
    try write("wal", to: URL(fileURLWithPath: legacy.path + "-wal"))
    try write("shm", to: URL(fileURLWithPath: legacy.path + "-shm"))
    // Sabotage: the -shm forward move fails (after store + wal already
    // moved), AND rolling the main store back from the destination fails —
    // the WAL would otherwise be rolled back while the store stays stuck at
    // the destination: exactly the orphaned-WAL silent-data-loss window.
    let fileManager = SabotagingFileManager(failingMoves: [
        legacy.path + "-shm", // forward move of -shm
        destination.path, // rollback move of the main store
    ])

    let outcome = StoreLocation.migrate(from: legacy, to: destination, fileManager: fileManager)

    guard case .failedForward = outcome else {
        Issue.record("expected .failedForward, got \(outcome)")
        return
    }
    // Fail-forward contract: the store and its WAL end up CO-LOCATED at the
    // destination (the -shm is rebuilt by SQLite and may be lost).
    #expect(exists(destination), "main store missing at destination after fail-forward")
    #expect(exists(destination, suffix: "-wal"), "WAL not co-located with store after fail-forward")
    #expect(!exists(legacy), "main store duplicated/left at legacy URL")
    #expect(!exists(legacy, suffix: "-wal"), "WAL orphaned at legacy URL")
    #expect(try String(contentsOf: destination, encoding: .utf8) == "store")
    #expect(try String(contentsOf: URL(fileURLWithPath: destination.path + "-wal"),
                       encoding: .utf8) == "wal")
}
