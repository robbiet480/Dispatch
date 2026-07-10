import Foundation

/// Phone-side nag/`lastActedAt` reconciliation for reports arriving via
/// CloudKit sync (plan 19): a report filed on another device (the watch's
/// quick answer in particular) must quiet an in-flight nag chain here, since
/// the remote device can neither reach this device's `lastActedAt` defaults
/// nor its pending notification requests.
///
/// Pure floor arithmetic with the three plan-mandated guards:
/// - **report-timestamp basis**: the floor advances from the report's OWN
///   date, never the sync-arrival time;
/// - **forward-only**: an already-later `lastActedAt` is never regressed;
/// - **historical arrivals ignored**: initial-sync backfill, imports, and
///   dedupe churn deliver reports whose dates fall outside any live nag
///   chain's lifetime — `window` (the caller derives it from the nag
///   chain's own maximum lifetime: delay + maxCount × interval, not a magic
///   constant) excludes them. Future-dated reports (cross-device clock
///   skew) are likewise excluded until their date actually passes.
public enum SyncedReportReconciler {
    /// The new `lastActedAt` floor implied by remotely-arrived report dates,
    /// or nil when nothing qualifies (nothing to do).
    public static func newFloor(
        reportDates: [Date],
        currentFloor: Date?,
        now: Date,
        window: TimeInterval
    ) -> Date? {
        let floor = currentFloor ?? .distantPast
        return reportDates
            .filter { date in
                date > floor
                    && date <= now
                    && now.timeIntervalSince(date) <= window
            }
            .max()
    }
}
