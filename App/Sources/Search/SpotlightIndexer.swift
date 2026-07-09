@preconcurrency import CoreSpotlight
import DispatchKit
import Foundation
import os

private let spotlightLog = Logger(subsystem: "io.robbie.Dispatch", category: "spotlight")

/// Indexes reports into the system-wide Spotlight index via CSSearchableIndex.
/// Every failure is logged and swallowed — indexing is best-effort and must
/// never surface an error to the user or block a save/delete flow.
/// Bypassed entirely under `--ui-testing`/`--mock-sensors` so UI/unit tests
/// never touch the real CoreSpotlight index.
enum SpotlightIndexer {
    static let domainIdentifier = "report"

    /// --mock-sensors/--ui-testing gate all indexing, matching the
    /// established test/mock-mode detection pattern (see NotificationScheduler).
    private static var isTestEnvironment: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--mock-sensors") || arguments.contains("--ui-testing")
    }

    static func index(report: Report) {
        guard !isTestEnvironment else { return }
        // Policy: while app lock is enabled, Dispatch does not index report content —
        // report text must not become searchable system-wide (e.g. from the lock
        // screen) while the user has explicitly asked for the app to be locked down.
        guard !AppLockStore.isEnabled() else {
            spotlightLog.info("skipping index for report \(report.uniqueIdentifier, privacy: .public): app lock enabled")
            return
        }
        // Hoist model reads before the completion closure: `report` is a SwiftData
        // model and must not be captured/read inside an async completion handler,
        // which can run after the context that owns it has changed or the object
        // has been invalidated. Only the plain hoisted `id` value is captured below.
        let id = report.uniqueIdentifier
        let item = searchableItem(for: report)
        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error {
                spotlightLog.error("failed to index report \(id, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    static func deindex(reportID: String) {
        guard !isTestEnvironment else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [reportID]) { error in
            if let error {
                spotlightLog.error("failed to deindex report \(reportID, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    /// Wipes the entire Spotlight index for this app. Used when app lock is enabled
    /// (see `AppLockStore.setEnabled`) so no previously-indexed report content
    /// remains searchable once the user has opted into locking the app down.
    /// Best-effort: logs and continues on failure, same as every other indexer op.
    static func deleteAll() {
        guard !isTestEnvironment else { return }
        CSSearchableIndex.default().deleteAllSearchableItems { error in
            if let error {
                spotlightLog.error("failed to delete all spotlight items: \(error, privacy: .public)")
            }
        }
    }

    /// Sendable snapshot of the pieces of a `CSSearchableItem` we need — built from
    /// `Report` (a SwiftData model, not Sendable) up front on the caller's context,
    /// so only plain value data crosses into the `@Sendable` completion handlers
    /// below. The actual (non-Sendable) `CSSearchableItem` is constructed from this
    /// snapshot only at the point of use, inside a single non-escaping closure body,
    /// so it never itself has to cross a `@Sendable` boundary.
    private struct SearchableItemSnapshot: Sendable {
        var uniqueIdentifier: String
        var title: String
        var contentDescription: String
    }

    static func rebuildAll(reports: [Report]) {
        guard !isTestEnvironment else { return }
        guard !AppLockStore.isEnabled() else {
            spotlightLog.info("skipping spotlight rebuild: app lock enabled")
            return
        }
        // Hoist model reads before any completion closure: `reports` are SwiftData
        // models and must not be captured/read inside an async completion handler
        // (see `index(report:)`). Only this Sendable snapshot array crosses into
        // the completion handlers below — not the reports and not any
        // CSSearchableItem.
        let snapshots = reports.map(snapshot(for:))
        CSSearchableIndex.default().deleteAllSearchableItems { deleteError in
            if let deleteError {
                spotlightLog.error("failed to clear spotlight index before rebuild: \(deleteError, privacy: .public)")
            }
            guard !snapshots.isEmpty else { return }
            let items = snapshots.map(searchableItem(for:))
            CSSearchableIndex.default().indexSearchableItems(items) { error in
                if let error {
                    spotlightLog.error("failed to rebuild spotlight index for \(snapshots.count, privacy: .public) reports: \(error, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Item construction

    private static func snapshot(for report: Report) -> SearchableItemSnapshot {
        SearchableItemSnapshot(
            uniqueIdentifier: report.uniqueIdentifier,
            title: title(for: report),
            contentDescription: contentDescription(for: report)
        )
    }

    private static func searchableItem(for snapshot: SearchableItemSnapshot) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = snapshot.title
        attributes.contentDescription = snapshot.contentDescription

        let item = CSSearchableItem(
            uniqueIdentifier: snapshot.uniqueIdentifier,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        // Report entries don't expire on their own (CoreSpotlight's default
        // expiration is ~30 days) — they should remain searchable indefinitely
        // until explicitly deindexed (delete) or wiped (app lock enabled).
        item.expirationDate = .distantFuture
        return item
    }

    private static func searchableItem(for report: Report) -> CSSearchableItem {
        searchableItem(for: snapshot(for: report))
    }

    private static func title(for report: Report) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: report.timeZoneIdentifier) ?? .gmt
        formatter.dateFormat = "MMM d, yyyy 'at' HH:mm"
        let dateString = formatter.string(from: report.date)

        if let place = placeText(for: report) {
            return "\(dateString) \u{2013} \(place)"
        }
        return dateString
    }

    private static func placeText(for report: Report) -> String? {
        guard let placemark = report.location?.placemark else { return nil }
        let parts = [placemark.name, placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func contentDescription(for report: Report) -> String {
        var snippets: [String] = []
        for response in report.responses ?? [] {
            if let textResponses = response.textResponses {
                snippets.append(contentsOf: textResponses.map(\.text))
            }
            if let tokens = response.tokens {
                snippets.append(contentsOf: tokens.map(\.text))
            }
            if let locationText = response.locationResponse?.text {
                snippets.append(locationText)
            }
        }
        return snippets.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}
