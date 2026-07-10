import Foundation
import Testing
@testable import DispatchKit

// promptSource(forIdentifier:) drives the settings "NEXT NOTIFICATION"
// hero caption: global prompts split into distribution vs scheduled-time
// by fire minute, group prompts surface their group ID, snoozes count as
// prompts, and nags/digest/webhook notices are NOT next prompts.

private let calendar = Calendar(identifier: .gregorian)

private func date(hour: Int, minute: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 7, day: 10,
                                       hour: hour, minute: minute))!
}

private func components(hour: Int, minute: Int) -> DateComponents {
    DateComponents(hour: hour, minute: minute)
}

@Test func globalPromptNotMatchingScheduledTimesIsDistribution() {
    let source = NotificationIdentifiers.promptSource(
        forIdentifier: "prompt-20260710-0930",
        fireDate: date(hour: 9, minute: 30),
        scheduledTimes: [components(hour: 8, minute: 0), components(hour: 21, minute: 15)],
        calendar: calendar)
    #expect(source == .distribution)
}

@Test func globalPromptMatchingAScheduledTimeIsScheduledTime() {
    let source = NotificationIdentifiers.promptSource(
        forIdentifier: "prompt-20260710-2115",
        fireDate: date(hour: 21, minute: 15),
        scheduledTimes: [components(hour: 21, minute: 15)],
        calendar: calendar)
    #expect(source == .scheduledTime)
}

@Test func globalPromptWithNoScheduledTimesIsDistribution() {
    let source = NotificationIdentifiers.promptSource(
        forIdentifier: "prompt-20260710-1200",
        fireDate: date(hour: 12, minute: 0),
        scheduledTimes: [],
        calendar: calendar)
    #expect(source == .distribution)
}

@Test func groupPromptYieldsItsGroupID() {
    // Group IDs are UUIDs — they contain dashes, so the parser must peel
    // exactly the trailing yyyyMMdd-HHmm stamp.
    let groupID = "1B9D6BCD-BBFD-4B2D-9B5D-AB8DFBBD4BED"
    let source = NotificationIdentifiers.promptSource(
        forIdentifier: "gprompt-\(groupID)-20260710-0845",
        fireDate: date(hour: 8, minute: 45),
        scheduledTimes: [],
        calendar: calendar)
    #expect(source == .promptGroup(groupID: groupID))
}

@Test func malformedGroupPromptIsNotAPrompt() {
    // A gprompt with no group segment before the stamp parses to nil
    // rather than inventing an empty group ID.
    let source = NotificationIdentifiers.promptSource(
        forIdentifier: "gprompt-20260710-0845",
        fireDate: date(hour: 8, minute: 45),
        scheduledTimes: [],
        calendar: calendar)
    #expect(source == nil)
}

@Test func snoozeIsAPromptSource() {
    let source = NotificationIdentifiers.promptSource(
        forIdentifier: "snooze-\(UUID().uuidString)",
        fireDate: date(hour: 10, minute: 0),
        scheduledTimes: [],
        calendar: calendar)
    #expect(source == .snooze)
}

@Test func nagsDigestAndWebhookNoticesAreExcluded() {
    for identifier in [
        "nag-20260710-0930-1",
        "nag-1B9D6BCD-BBFD-4B2D-9B5D-AB8DFBBD4BED-20260710-0930-2",
        // Old pre-plan-40 request (still exists in the wild) …
        "digest-weekly",
        // … and the plan-40 per-schedule scheme — both stay NON-prompts.
        "digest-\(UUID().uuidString)",
        "webhook-failed-some-report-id",
        "something-else-entirely",
    ] {
        let source = NotificationIdentifiers.promptSource(
            forIdentifier: identifier,
            fireDate: date(hour: 9, minute: 30),
            scheduledTimes: [components(hour: 9, minute: 30)],
            calendar: calendar)
        #expect(source == nil, "\(identifier) should not be a next prompt")
    }
}
