import Foundation

/// Plan 37 — sync diagnostics.
///
/// A bounded, persisted ring buffer of sanitized sync events, plus the value
/// types it holds. Everything here is plain Foundation on purpose: the pieces
/// are pure and testable, with no SwiftData or CloudKit imports. The app-side
/// `SyncDiagnostics` (a `@MainActor @Observable`) owns an instance of this and
/// persists it into the appDefaults suite.
///
/// PRIVACY: a record's `detail` is ALWAYS pre-sanitized by its caller via
/// `SyncEventRecord.sanitize(error:)` (for error kinds) or a caller-built
/// count string (e.g. "removed 3 duplicates"). A raw error is NEVER dumped
/// into `detail` — see the privacy contract pinned by `SyncDiagnosticsReport`
/// tests.

/// The vocabulary of observable sync events. Backed by a raw `String` for wire
/// leniency: an older build reading a buffer written by a newer build (which
/// may carry a kind this build doesn't know) decodes and re-encodes the raw
/// untouched instead of crashing — see `SyncEventRecord.kind`.
public enum SyncEventKind: String, Codable, Sendable, CaseIterable {
    /// An `NSPersistentStoreRemoteChange` burst was observed (plan 13 pipeline).
    case remoteChange
    /// A dedupe pipeline pass completed; `detail` carries the merge counts,
    /// `succeeded` is true. Zero-removal passes are recorded too — zero is
    /// evidence.
    case dedupePass
    /// The pipeline threw; `detail` carries the sanitized error, `succeeded`
    /// is false.
    case pipelineError
    /// CloudKit mirroring setup finished (`eventChangedNotification`,
    /// probe-gated).
    case ckSetup
    /// A CloudKit import finished (`eventChangedNotification`, probe-gated).
    case ckImport
    /// A CloudKit export finished (`eventChangedNotification`, probe-gated).
    case ckExport

    /// Human-facing label for the diagnostics timeline.
    public var displayName: String {
        switch self {
        case .remoteChange: "Store change observed"
        case .dedupePass: "Dedupe pass"
        case .pipelineError: "Pipeline error"
        case .ckSetup: "iCloud setup"
        case .ckImport: "iCloud import"
        case .ckExport: "iCloud export"
        }
    }
}

/// One recorded sync event. Codable value type; the wire form stores the kind
/// as a raw string so unknown kinds survive a decode/encode round-trip.
public struct SyncEventRecord: Codable, Sendable, Equatable {
    public var date: Date
    /// Raw kind string. Preserved verbatim across round-trips even when it
    /// names a kind this build doesn't recognize (leniency norm).
    public var kindRaw: String
    /// Whether the event's operation succeeded. `nil` for kinds where success
    /// is not a meaningful axis (e.g. `remoteChange`).
    public var succeeded: Bool?
    /// Pre-sanitized detail string (counts or a sanitized error). NEVER a raw
    /// error dump or any report content — see the file-level privacy note.
    public var detail: String?

    public init(date: Date, kindRaw: String, succeeded: Bool?, detail: String?) {
        self.date = date
        self.kindRaw = kindRaw
        self.succeeded = succeeded
        self.detail = detail
    }

    /// Typed accessor over `kindRaw`; `nil` when the raw string names a kind
    /// this build doesn't know (the UI falls back to showing the raw string).
    public var kind: SyncEventKind? {
        SyncEventKind(rawValue: kindRaw)
    }

    /// Renders an error to a bounded, userInfo-free string safe for the
    /// diagnostics dump: `domain(code): localizedDescription`, with the
    /// description truncated to 200 characters. Truncation plus dropping
    /// userInfo keeps the privacy guarantee structural — CloudKit record
    /// names are UUIDs, but they never reach here because nothing beyond the
    /// localizedDescription is included.
    public static func sanitize(error: Error) -> String {
        let nsError = error as NSError
        let description = nsError.localizedDescription
        let truncated = description.count > 200
            ? String(description.prefix(200))
            : description
        return "\(nsError.domain)(\(nsError.code)): \(truncated)"
    }
}

/// A bounded ring buffer of `SyncEventRecord`s with JSON persistence into a
/// single defaults key. Device-local by design: diagnostics describe THIS
/// device's observations (the per-device nag-state precedent from plan 13).
public struct SyncEventLog: Codable, Sendable, Equatable {
    /// Maximum retained records. 50 × ~120 bytes is well under any
    /// defaults-size concern while keeping a useful tail across relaunch.
    public let capacity: Int
    private var storage: [SyncEventRecord]

    public init(capacity: Int = 50) {
        self.capacity = capacity
        self.storage = []
    }

    /// Records, oldest-first (the timeline UI reverses for newest-first).
    public var records: [SyncEventRecord] { storage }

    /// Appends a record, trimming the oldest to stay within `capacity`.
    public mutating func append(_ record: SyncEventRecord) {
        storage.append(record)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    // MARK: - Persistence

    private enum CodingKeys: String, CodingKey {
        case capacity, storage
    }

    /// JSON-encodes the buffer for a single defaults key.
    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decodes a persisted buffer. Corrupt or nil data yields an empty log —
    /// never a throw, so a bad stored blob can't prevent launch or crash the
    /// diagnostics screen.
    public init(decodingFrom data: Data?, capacity: Int = 50) {
        guard let data,
              let decoded = try? JSONDecoder().decode(SyncEventLog.self, from: data) else {
            self.init(capacity: capacity)
            return
        }
        self = decoded
    }
}
