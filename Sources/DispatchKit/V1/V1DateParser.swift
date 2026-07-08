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
        // Normalize offset: if it ends with ±HH:mm, remove the colon to get ±HHmm.
        let normalized: String
        if string.count >= 6 {
            let maybeTail = String(string.suffix(6))
            if let sign = maybeTail.first, sign == "+" || sign == "-" {
                let offsetPart = String(maybeTail.dropFirst())
                if offsetPart.count == 5 && offsetPart[offsetPart.index(offsetPart.startIndex, offsetBy: 2)] == ":" {
                    // Found ±HH:mm — remove the colon.
                    let base = String(string.dropLast(6))
                    let hours = String(offsetPart.prefix(2))
                    let minutes = String(offsetPart.suffix(2))
                    normalized = base + String(sign) + hours + minutes
                } else {
                    normalized = string
                }
            } else {
                normalized = string
            }
        } else {
            normalized = string
        }

        guard let date = formatter.date(from: normalized) else { return nil }
        // Offset is the trailing ±HHmm.
        guard normalized.count >= 5 else { return nil }
        let tail = String(normalized.suffix(5))
        guard let sign = tail.first, sign == "+" || sign == "-",
              let hours = Int(tail.dropFirst().prefix(2)),
              let minutes = Int(tail.suffix(2)) else { return nil }
        let magnitude = hours * 3600 + minutes * 60
        return (date, sign == "-" ? -magnitude : magnitude)
    }
}
