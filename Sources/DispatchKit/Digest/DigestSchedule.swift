import Foundation

/// A user-configurable digest reminder (plan 40, reworking plan 14's single
/// hardcoded Sunday-19:00 toggle). Pure and Foundation-only: all date math
/// takes an injected `Calendar`, never reads `Date()` or `Locale.current`,
/// and uses explicit tiebreaks so tests can pin a zone (DST cases pin
/// `America/New_York`).
///
/// Cadence semantics (logged decisions):
/// - `.weekly(weekday:)` uses the `Calendar` convention (1 = Sunday … 7 =
///   Saturday).
/// - `.monthly(dayOfMonth:)` fires the chosen day 1…31 **clamped to the
///   actual month length** — 31 means "month-end", so February fires on the
///   28th/29th, April on the 30th. Clamping, never skipping.
/// - `.quarterly(dayOfMonth:)` fires the chosen day (same clamping) in each
///   calendar-quarter START month — Jan/Apr/Jul/Oct — so a quarterly digest
///   early in the new quarter reviews the quarter that just ended via the
///   trailing `DigestPeriod` window.
public struct DigestSchedule: Codable, Equatable, Identifiable, Sendable {
    public enum Cadence: Codable, Equatable, Sendable {
        case weekly(weekday: Int)       // 1 = Sunday … 7 = Saturday
        case monthly(dayOfMonth: Int)   // 1…31, clamped to each month's length
        case quarterly(dayOfMonth: Int) // fires in Jan/Apr/Jul/Oct, same clamping

        public var period: DigestPeriod {
            switch self {
            case .weekly: return .week
            case .monthly: return .month
            case .quarterly: return .quarter
            }
        }
    }

    public var id: UUID
    public var cadence: Cadence
    public var hour: Int
    public var minute: Int
    public var isEnabled: Bool

    public init(id: UUID, cadence: Cadence, hour: Int, minute: Int, isEnabled: Bool) {
        self.id = id
        self.cadence = cadence
        self.hour = hour
        self.minute = minute
        self.isEnabled = isEnabled
    }

    /// Components for a REPEATING `UNCalendarNotificationTrigger`, or nil when
    /// the cadence can't be expressed as one: monthly day 29–31 (clamping is
    /// not expressible in matching components) and quarterly (no multi-month
    /// component set). When nil, the caller re-arms a one-shot trigger from
    /// `nextFireDate` on each replan.
    public var repeatingTriggerComponents: DateComponents? {
        switch cadence {
        case let .weekly(weekday):
            return DateComponents(hour: hour, minute: minute, weekday: weekday)
        case let .monthly(dayOfMonth) where dayOfMonth <= 28:
            return DateComponents(day: dayOfMonth, hour: hour, minute: minute)
        case .monthly, .quarterly:
            return nil
        }
    }

    /// Next wall-clock fire strictly after `now`. Weekly delegates to
    /// `Calendar.nextDate` (DST-correct, `.nextTime` rolls a nonexistent
    /// spring-forward instant to the next valid one); monthly/quarterly scan
    /// candidate months forward, clamping the day via `range(of: .day, in:
    /// .month, for:)`.
    public func nextFireDate(after now: Date, calendar: Calendar = .current) -> Date? {
        switch cadence {
        case let .weekly(weekday):
            return calendar.nextDate(
                after: now,
                matching: DateComponents(hour: hour, minute: minute, weekday: weekday),
                matchingPolicy: .nextTime)
        case let .monthly(dayOfMonth):
            return nextMonthlyFire(day: dayOfMonth, anchorMonths: nil,
                                   after: now, calendar: calendar)
        case let .quarterly(dayOfMonth):
            return nextMonthlyFire(day: dayOfMonth, anchorMonths: [1, 4, 7, 10],
                                   after: now, calendar: calendar)
        }
    }

    /// Scans month starts forward from `now`'s month, clamping the requested
    /// day to each month's length, and returns the first candidate strictly
    /// after `now`. `anchorMonths` (nil = every month) restricts quarterly
    /// firing to the calendar-quarter start months. 14 iterations covers
    /// every case (a full year of anchors plus wrap slack).
    private func nextMonthlyFire(day: Int, anchorMonths: Set<Int>?,
                                 after now: Date, calendar: Calendar) -> Date? {
        let nowComponents = calendar.dateComponents([.year, .month], from: now)
        guard let monthStart = calendar.date(from: nowComponents) else { return nil }

        for offset in 0..<14 {
            guard let candidateMonth = calendar.date(byAdding: .month, value: offset,
                                                     to: monthStart) else { continue }
            let monthComponent = calendar.component(.month, from: candidateMonth)
            if let anchorMonths, !anchorMonths.contains(monthComponent) { continue }
            guard let dayRange = calendar.range(of: .day, in: .month, for: candidateMonth) else {
                continue
            }
            let clampedDay = min(day, dayRange.upperBound - 1)
            var components = calendar.dateComponents([.year, .month], from: candidateMonth)
            components.day = clampedDay
            components.hour = hour
            components.minute = minute
            guard let candidate = calendar.date(from: components) else { continue }
            if candidate > now { return candidate }
        }
        return nil
    }
}

/// The window a digest reviews: a trailing interval, not a calendar-aligned
/// period. Generalizes plan-14's weekly rule (7 days ending the day after
/// `ending`) to a month or a quarter by swapping the trailing-step unit.
/// Calendar-aligned review (THE March, THE 2026) is Wrapped's job (plan 33).
public enum DigestPeriod: String, Codable, Sendable, CaseIterable {
    case week, month, quarter

    /// Singular noun for period-aware copy ("this week"/"this month"/…).
    public var noun: String {
        switch self {
        case .week: return "week"
        case .month: return "month"
        case .quarter: return "quarter"
        }
    }

    /// Trailing window ending at (and excluding) the start of the day after
    /// `ending`. `priorStart` begins the same-length window immediately
    /// before `start` (for deltas/trends).
    public func interval(ending: Date, calendar: Calendar = .current)
        -> (start: Date, end: Date, priorStart: Date) {
        let end = calendar.date(byAdding: .day, value: 1,
                                to: calendar.startOfDay(for: ending))!
        let start: Date
        switch self {
        case .week:
            start = calendar.date(byAdding: .day, value: -7, to: end)!
        case .month:
            start = calendar.date(byAdding: .month, value: -1, to: end)!
        case .quarter:
            start = calendar.date(byAdding: .month, value: -3, to: end)!
        }
        let priorStart: Date
        switch self {
        case .week:
            priorStart = calendar.date(byAdding: .day, value: -7, to: start)!
        case .month:
            priorStart = calendar.date(byAdding: .month, value: -1, to: start)!
        case .quarter:
            priorStart = calendar.date(byAdding: .month, value: -3, to: start)!
        }
        return (start: start, end: end, priorStart: priorStart)
    }
}
