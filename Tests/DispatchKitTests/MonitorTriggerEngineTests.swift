import Foundation
import Testing
@testable import DispatchKit

private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

@Test func arrivalSatisfiedSchedulesAtEventPlusDelay() {
    let outcome = MonitorTriggerEngine.outcome(
        direction: .arrival, delayMinutes: 30, cancelOnContradiction: true,
        state: .satisfied, eventDate: t0)
    #expect(outcome == .schedule(fireDate: t0.addingTimeInterval(30 * 60)))
}

@Test func arrivalZeroDelayFiresImmediately() {
    let outcome = MonitorTriggerEngine.outcome(
        direction: .arrival, delayMinutes: 0, cancelOnContradiction: true,
        state: .satisfied, eventDate: t0)
    #expect(outcome == .schedule(fireDate: t0))
}

@Test func arrivalUnsatisfiedCancelsWhenConfigured() {
    let outcome = MonitorTriggerEngine.outcome(
        direction: .arrival, delayMinutes: 30, cancelOnContradiction: true,
        state: .unsatisfied, eventDate: t0)
    #expect(outcome == .cancelPending)
}

@Test func arrivalUnsatisfiedIgnoredWhenCancelDisabled() {
    let outcome = MonitorTriggerEngine.outcome(
        direction: .arrival, delayMinutes: 30, cancelOnContradiction: false,
        state: .unsatisfied, eventDate: t0)
    #expect(outcome == .ignore)
}

@Test func departureFiresOnUnsatisfiedAndCancelsOnSatisfied() {
    let fire = MonitorTriggerEngine.outcome(
        direction: .departure, delayMinutes: 10, cancelOnContradiction: true,
        state: .unsatisfied, eventDate: t0)
    #expect(fire == .schedule(fireDate: t0.addingTimeInterval(10 * 60)))

    let cancel = MonitorTriggerEngine.outcome(
        direction: .departure, delayMinutes: 10, cancelOnContradiction: true,
        state: .satisfied, eventDate: t0)
    #expect(cancel == .cancelPending)
}

@Test func unknownStateIsAlwaysIgnored() {
    for direction in MonitorDirection.allCases {
        let outcome = MonitorTriggerEngine.outcome(
            direction: direction, delayMinutes: 5, cancelOnContradiction: true,
            state: .unknown, eventDate: t0)
        #expect(outcome == .ignore)
    }
}

@Test func negativeDelayClampsToImmediate() {
    let outcome = MonitorTriggerEngine.outcome(
        direction: .arrival, delayMinutes: -5, cancelOnContradiction: true,
        state: .satisfied, eventDate: t0)
    #expect(outcome == .schedule(fireDate: t0))
}
