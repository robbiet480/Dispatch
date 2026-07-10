import Foundation
import Testing
@testable import DispatchKit

// Plan 19: forwarded-notification action routing on the watch — the
// unit-testable identifier → behavior mapping.

@Test func yesAndNoActionsFileDirectly() {
    #expect(WatchNotificationAction.route(actionIdentifier: "answer-yes")
        == .fileAnswer(isYes: true))
    #expect(WatchNotificationAction.route(actionIdentifier: "answer-no")
        == .fileAnswer(isYes: false))
}

@Test func snoozeIsADocumentedNoOp() {
    #expect(WatchNotificationAction.route(actionIdentifier: "snooze") == .snoozeNoOp)
}

@Test func defaultTapAndUnknownActionsOpenTheApp() {
    // UNNotificationDefaultActionIdentifier's raw value (UserNotifications
    // is platform UI; the kit mapping treats it as any unknown identifier).
    #expect(WatchNotificationAction.route(
        actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier") == .openApp)
    #expect(WatchNotificationAction.route(actionIdentifier: "some-future-action") == .openApp)
    #expect(WatchNotificationAction.route(actionIdentifier: "") == .openApp)
}
