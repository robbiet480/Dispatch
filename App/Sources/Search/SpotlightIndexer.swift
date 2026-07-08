import CoreSpotlight
import DispatchKit
import Foundation
import MobileCoreServices
import os

private let spotlightLog = Logger(subsystem: "com.robbiet480.dispatch", category: "spotlight")

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
        let item = searchableItem(for: report)
        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error {
                spotlightLog.error("failed to index report \(report.uniqueIdentifier, privacy: .public): \(error, privacy: .public)")
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

    static func rebuildAll(reports: [Report]) {
        guard !isTestEnvironment else { return }
        CSSearchableIndex.default().deleteAllSearchableItems { deleteError in
            if let deleteError {
                spotlightLog.error("failed to clear spotlight index before rebuild: \(deleteError, privacy: .public)")
            }
            let items = reports.map(searchableItem(for:))
            guard !items.isEmpty else { return }
            CSSearchableIndex.default().indexSearchableItems(items) { error in
                if let error {
                    spotlightLog.error("failed to rebuild spotlight index: \(error, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Item construction

    private static func searchableItem(for report: Report) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title(for: report)
        attributes.contentDescription = contentDescription(for: report)

        let item = CSSearchableItem(
            uniqueIdentifier: report.uniqueIdentifier,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        return item
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
        for response in report.responses {
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
