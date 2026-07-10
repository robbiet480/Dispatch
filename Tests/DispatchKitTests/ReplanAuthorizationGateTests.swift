import Testing
import UserNotifications

@testable import DispatchKit

@Suite("ReplanAuthorizationGate")
struct ReplanAuthorizationGateTests {
    @Test("authorized, provisional, and ephemeral statuses allow scheduling")
    func grantedStatusesSchedule() {
        #expect(ReplanAuthorizationGate.canSchedule(.authorized))
        #expect(ReplanAuthorizationGate.canSchedule(.provisional))
        // .ephemeral is unavailable on macOS, where `swift test` runs.
        #if !os(macOS)
        #expect(ReplanAuthorizationGate.canSchedule(.ephemeral))
        #endif
    }

    @Test("denied and notDetermined skip — every add would fail with 'Source is not authorized'")
    func ungrantedStatusesSkip() {
        #expect(!ReplanAuthorizationGate.canSchedule(.denied))
        #expect(!ReplanAuthorizationGate.canSchedule(.notDetermined))
    }
}
