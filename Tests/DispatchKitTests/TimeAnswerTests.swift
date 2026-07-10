import Foundation
import Testing
@testable import DispatchKit

// MARK: - Raw value freeze

/// The QuestionType raw values are a wire contract — renumbering any of them
/// silently corrupts every synced/exported store. Pin all eight literally so a
/// stray edit fails loudly here.
@Test func questionTypeRawValuesAreFrozen() {
    #expect(QuestionType.tokens.rawValue == 0)
    #expect(QuestionType.multipleChoice.rawValue == 1)
    #expect(QuestionType.yesNo.rawValue == 2)
    #expect(QuestionType.location.rawValue == 3)
    #expect(QuestionType.people.rawValue == 4)
    #expect(QuestionType.number.rawValue == 5)
    #expect(QuestionType.note.rawValue == 6)
    #expect(QuestionType.time.rawValue == 7)
}

// MARK: - Wire shape

@Test func timeAnswerOmitsDayOffsetWhenZero() throws {
    let data = try JSONEncoder().encode(TimeAnswer(minutesSinceMidnight: 540))
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"minutes\""))
    #expect(!json.contains("dayOffset"))
}

@Test func timeAnswerEncodesDayOffsetWhenNonZero() throws {
    let data = try JSONEncoder().encode(TimeAnswer(minutesSinceMidnight: 540, dayOffset: -1))
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"dayOffset\""))
}

@Test func timeAnswerDecodesMissingDayOffsetAsZero() throws {
    let answer = try JSONDecoder().decode(TimeAnswer.self, from: Data(#"{"minutes": 540}"#.utf8))
    #expect(answer.minutesSinceMidnight == 540)
    #expect(answer.dayOffset == 0)
}

/// Leniency: an out-of-domain dayOffset imports, persists, and re-exports untouched.
@Test func timeAnswerPreservesUnknownDayOffsetThroughReencode() throws {
    let answer = try JSONDecoder().decode(TimeAnswer.self, from: Data(#"{"minutes": 90, "dayOffset": -3}"#.utf8))
    #expect(answer.dayOffset == -3)
    let reencoded = try JSONEncoder().encode(answer)
    let roundTripped = try JSONDecoder().decode(TimeAnswer.self, from: reencoded)
    #expect(roundTripped.dayOffset == -3)
}

// MARK: - clampedMinutes

@Test func clampedMinutesClampsToDomain() {
    #expect(TimeAnswer(minutesSinceMidnight: -10).clampedMinutes == 0)
    #expect(TimeAnswer(minutesSinceMidnight: 2000).clampedMinutes == 1439)
    #expect(TimeAnswer(minutesSinceMidnight: 540).clampedMinutes == 540)
}

// MARK: - hhmm

@Test func hhmmFormatsZeroPadded24Hour() {
    #expect(TimeAnswer(minutesSinceMidnight: 540).hhmm == "09:00")
    #expect(TimeAnswer(minutesSinceMidnight: 0).hhmm == "00:00")
    #expect(TimeAnswer(minutesSinceMidnight: 1439).hhmm == "23:59")
    #expect(TimeAnswer(minutesSinceMidnight: 2000).hhmm == "23:59") // clamped
}

// MARK: - displayText

@Test func displayTextIsLocaleAwareWithYesterdaySuffix() {
    let locale = Locale(identifier: "en_US")
    // Newer OSes place a narrow no-break space (U+202F) before AM/PM; normalize
    // whitespace so the assertion tracks meaning, not the platform's space glyph.
    func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
    #expect(normalized(TimeAnswer(minutesSinceMidnight: 540, dayOffset: 0).displayText(locale: locale)) == "9:00 AM")
    #expect(normalized(TimeAnswer(minutesSinceMidnight: 1350, dayOffset: -1).displayText(locale: locale)) == "10:30 PM (yesterday)")
}

// MARK: - now

@Test func nowReturnsWallClockMinuteWithZeroOffset() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    // 2021-06-15 08:37 local.
    let components = DateComponents(year: 2021, month: 6, day: 15, hour: 8, minute: 37)
    let date = calendar.date(from: components)!
    let answer = TimeAnswer.now(date, calendar: calendar)
    #expect(answer.minutesSinceMidnight == 8 * 60 + 37)
    #expect(answer.dayOffset == 0)
}
