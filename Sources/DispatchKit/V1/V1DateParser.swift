import Foundation

/// Parses the original Reporter export's date strings, e.g. "2016-02-11T19:08:54-0400".
public enum V1DateParser {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    public static func parse(_ string: String) -> (date: Date, utcOffsetSeconds: Int)? {
        guard let date = formatter.date(from: string) else { return nil }
        // Offset is the trailing ±HHmm.
        guard string.count >= 5 else { return nil }
        let tail = String(string.suffix(5))
        guard let sign = tail.first, sign == "+" || sign == "-",
              let hours = Int(tail.dropFirst().prefix(2)),
              let minutes = Int(tail.suffix(2)) else { return nil }
        let magnitude = hours * 3600 + minutes * 60
        return (date, sign == "-" ? -magnitude : magnitude)
    }
}
