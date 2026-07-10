import Foundation
import Testing

@testable import DispatchKit

/// BackupWriter (plan 25 follow-up): the per-destination write/rotate pass,
/// exercised against temp-directory stand-ins. The space-in-path case is the
/// regression test for the first-launch iCloud failure — the ubiquity
/// container lives under `Mobile Documents`, and the old
/// `contentsOfDirectory(atPath: url.path())` listing percent-encoded the
/// space and threw Cocoa error 260 ("The folder Backups doesn't exist").
@Suite("BackupWriter")
struct BackupWriterTests {
    private let slug = "iPhone17-1-ab12cd34"

    private func makeTempDirectory(component: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupWriterTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    @Test("creates missing directory (and intermediates) before the first write")
    func createsDirectoryOnFirstWrite() throws {
        let directory = makeTempDirectory(component: "Documents")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))

        let filename = BackupRotation.backupFilename(for: Date(), slug: slug)
        let count = try BackupWriter.writeAndRotate(
            data: Data("{}".utf8), filename: filename, in: directory, slug: slug)

        #expect(count == 1)
        let written = directory.appendingPathComponent(filename)
        #expect(FileManager.default.fileExists(atPath: written.path(percentEncoded: false)))
    }

    @Test("succeeds when the directory path contains a space (ubiquity 'Mobile Documents' regression)")
    func succeedsWithSpaceInPath() throws {
        let directory = makeTempDirectory(component: "Mobile Documents")
        defer { try? FileManager.default.removeItem(at: directory) }

        let filename = BackupRotation.backupFilename(for: Date(), slug: slug)
        let count = try BackupWriter.writeAndRotate(
            data: Data("{}".utf8), filename: filename, in: directory, slug: slug)

        #expect(count == 1)
        let written = directory.appendingPathComponent(filename)
        #expect(FileManager.default.fileExists(atPath: written.path(percentEncoded: false)))
    }

    @Test("prunes rotation-expired backups and ignores foreign files")
    func prunesExpiredBackupsOnly() throws {
        let directory = makeTempDirectory(component: "Documents")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Three older backups plus a foreign file rotation must never touch.
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        var olderNames: [String] = []
        for daysAgo in 1...3 {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            let name = BackupRotation.backupFilename(for: date, slug: slug)
            olderNames.append(name)
            try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
        }
        let foreign = directory.appendingPathComponent("keep-me.txt")
        try Data("user file".utf8).write(to: foreign)

        // keep: 2 ⇒ the new write survives with the newest older backup;
        // the two oldest are pruned.
        let count = try BackupWriter.writeAndRotate(
            data: Data("{}".utf8), filename: BackupRotation.backupFilename(for: now, slug: slug),
            in: directory, slug: slug, keep: 2)

        #expect(count == 2)
        #expect(FileManager.default.fileExists(atPath: foreign.path(percentEncoded: false)))
        let survivors = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ).map(\.lastPathComponent)
        #expect(!survivors.contains(olderNames[1])) // 2 days ago — pruned
        #expect(!survivors.contains(olderNames[2])) // 3 days ago — pruned
        #expect(survivors.contains(olderNames[0])) // yesterday — kept
    }

    @Test("rotation in a shared folder never deletes another device's or legacy backups")
    func rotationScopedToOwnSlugOnDisk() throws {
        let directory = makeTempDirectory(component: "Mobile Documents")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        // Another device's backups and a legacy un-slugged backup, all OLDER
        // than everything this device writes.
        let otherSlug = "iPad16-3-99ee00ff"
        var untouchable: [String] = []
        for daysAgo in 10...12 {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            let name = BackupRotation.backupFilename(for: date, slug: otherSlug)
            untouchable.append(name)
            try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
        }
        let legacyName = "dispatch-backup-2024-12-01-0900.json" // pre-slug shape, ancient
        try Data("{}".utf8).write(to: directory.appendingPathComponent(legacyName))
        untouchable.append(legacyName)

        // Two of ours, then a third with keep: 1 → only OUR oldest two go.
        var mine: [String] = []
        for daysAgo in 1...2 {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            let name = BackupRotation.backupFilename(for: date, slug: slug)
            mine.append(name)
            try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
        }
        let count = try BackupWriter.writeAndRotate(
            data: Data("{}".utf8), filename: BackupRotation.backupFilename(for: now, slug: slug),
            in: directory, slug: slug, keep: 1)

        #expect(count == 1) // scoped count: only this device's survivors
        let survivors = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ).map(\.lastPathComponent)
        for name in untouchable {
            #expect(survivors.contains(name), "must never delete \(name)")
        }
        #expect(!survivors.contains(mine[0]))
        #expect(!survivors.contains(mine[1]))
    }
}
