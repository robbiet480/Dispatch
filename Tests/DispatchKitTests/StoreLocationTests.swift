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
