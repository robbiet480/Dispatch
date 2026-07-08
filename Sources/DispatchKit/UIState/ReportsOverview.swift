import Foundation

public struct DaySection: Identifiable {
    public let id: String
    public let weekday: String
    public let dateLabel: String
    public let reports: [Report]
}

public enum ReportsOverview {
    private static func localDayKey(_ report: Report) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: report.timeZoneIdentifier) ?? .gmt
        let comps = calendar.dateComponents([.year, .month, .day], from: report.date)
        return String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
    }

    private static func labels(_ report: Report) -> (weekday: String, date: String) {
        let tz = TimeZone(identifier: report.timeZoneIdentifier) ?? .gmt
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "en_US_POSIX")
        weekdayFormatter.timeZone = tz
        weekdayFormatter.dateFormat = "EEEE"
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = tz
        dateFormatter.dateFormat = "MMM d, yyyy"
        return (weekdayFormatter.string(from: report.date).uppercased(),
                dateFormatter.string(from: report.date).uppercased())
    }

    public static func sections(from reports: [Report]) -> [DaySection] {
        let grouped = Dictionary(grouping: reports, by: localDayKey)
        return grouped
            .sorted { $0.key > $1.key }
            .map { key, dayReports in
                let sorted = dayReports.sorted { $0.date > $1.date }
                let label = labels(sorted[0])
                return DaySection(id: key, weekday: label.weekday,
                                  dateLabel: label.date, reports: sorted)
            }
    }

    public static func stats(from reports: [Report]) -> (reports: Int, days: Int, avgPerDay: Double) {
        guard !reports.isEmpty else { return (0, 0, 0) }
        let days = Set(reports.map(localDayKey)).count
        return (reports.count, days, Double(reports.count) / Double(days))
    }

    public static func secondaryStats(reports: [Report], tokenCount: Int, personCount: Int)
        -> (tokens: Int, locations: Int, people: Int) {
        var places = Set<String>()
        for report in reports {
            for response in report.responses {
                if let location = response.locationResponse {
                    if let venue = location.foursquareVenueId {
                        places.insert("venue:\(venue)")
                    } else if let text = location.text, !text.isEmpty {
                        places.insert("text:\(text)")
                    }
                }
            }
        }
        return (tokenCount, places.count, personCount)
    }
}
