import Foundation

/// Pure streak math shared by the widget snapshot and the weekly digest:
/// the number of consecutive local calendar days ending today (or yesterday,
/// when today has no report yet) with at least one non-draft report.
public enum ReportStreak {
    public static func days(reports: [Report], now: Date, calendar: Calendar) -> Int {
        let dayStarts = Set(
            reports.lazy
                .filter { !$0.isDraft }
                .map { calendar.startOfDay(for: $0.date) }
        )
        guard !dayStarts.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: now)
        var cursor: Date
        if dayStarts.contains(today) {
            cursor = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  dayStarts.contains(yesterday) {
            // Today's report may simply not be filed yet — a streak through
            // yesterday still counts (it hasn't been broken until midnight).
            cursor = yesterday
        } else {
            return 0
        }

        var streak = 0
        while dayStarts.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}

/// The data a home/lock-screen widget renders: computed in the widget process
/// from a read-only fetch of the shared App Group store (the widget never
/// writes; the app pokes `WidgetCenter.reloadAllTimelines()` on save/replan).
/// Pure and Foundation-only so the math is unit-testable.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// Date of the most recent non-draft report, nil when none exist.
    public var lastReportDate: Date?
    /// Non-draft reports filed during the current local calendar day.
    public var todayCount: Int
    /// Consecutive report days ending today/yesterday (see `ReportStreak`).
    public var streakDays: Int
    /// The next scheduled prompt fire date, when one is known.
    public var nextPromptDate: Date?

    public init(lastReportDate: Date? = nil, todayCount: Int = 0,
                streakDays: Int = 0, nextPromptDate: Date? = nil) {
        self.lastReportDate = lastReportDate
        self.todayCount = todayCount
        self.streakDays = streakDays
        self.nextPromptDate = nextPromptDate
    }

    /// Aggregates `reports` (drafts excluded) into the widget's display data.
    /// `nextPromptDate` is passed through untouched — prompt scheduling lives
    /// with the planner, not here.
    public static func compute(reports: [Report], nextPromptDate: Date? = nil,
                               now: Date = Date(), calendar: Calendar = .current) -> WidgetSnapshot {
        let filed = reports.filter { !$0.isDraft }
        let todayStart = calendar.startOfDay(for: now)
        let todayCount = filed.count { report in
            calendar.startOfDay(for: report.date) == todayStart
        }
        return WidgetSnapshot(
            lastReportDate: filed.map(\.date).max(),
            todayCount: todayCount,
            streakDays: ReportStreak.days(reports: filed, now: now, calendar: calendar),
            nextPromptDate: nextPromptDate
        )
    }
}
