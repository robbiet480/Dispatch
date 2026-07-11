import Foundation

/// CLMonitor's monitored-condition budget is limited (~20) and SHARED across
/// the geographic (#56) and beacon (#60) conditions — one monitor owns both.
/// This pure allocator caps the combined enabled set in priority order so the
/// observer registers only what fits and can surface which groups were
/// dropped (an inline "not monitored — over the limit" hint).
public enum MonitorConditionBudget {
    /// Apple does not publish an exact number; ~20 is the widely-observed
    /// ceiling. Conservative and easy to bump if the platform documents more.
    public static let defaultLimit = 20

    /// Splits `groupIDs` (enabled place+beacon groups, already in sortOrder =
    /// priority) into those that fit within `limit` and those dropped. A
    /// non-positive limit drops everything; the input order is preserved.
    public static func allocate(
        groupIDs: [String], limit: Int = defaultLimit
    ) -> (registered: [String], dropped: [String]) {
        let capped = max(0, limit)
        return (Array(groupIDs.prefix(capped)), Array(groupIDs.dropFirst(capped)))
    }
}
