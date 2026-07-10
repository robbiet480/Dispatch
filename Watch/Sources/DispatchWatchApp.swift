import DispatchKit
import SwiftData
import SwiftUI
import UserNotifications
import WatchKit

/// The independent (companion-style) watch app (plan 19): quick answers and
/// minimal report filing from the wrist, synced through the same private
/// CloudKit database as the phones. No WatchConnectivity anywhere in v1 —
/// Apple: independent apps "can't rely on the Watch Connectivity framework";
/// CloudKit is the named sync path
/// (https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps).
///
/// Deliberately absent (the phone stays pipeline authority):
/// - no RemoteChangeObserver / SyncDedupe / Spotlight / vocabulary rebuilds;
/// - no notification scheduling of ANY kind (see plan §design-decisions —
///   watch-local scheduling would double-prompt; the phone's local
///   notifications forward to the watch automatically);
/// - no default-question seeding (questions arrive via sync; seeding here
///   would race the phone's authority for no benefit — a watch without a
///   phone-synced store shows an empty list and still works once sync runs).
@main
struct DispatchWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    let container: ModelContainer
    /// Strong reference — UNUserNotificationCenter.delegate is weak/unowned.
    let notificationDelegate: WatchNotificationDelegate
    private let isTestEnvironment: Bool

    init() {
        // Device provenance (plan 19): inject the device name for report
        // stamping. Read UNCONDITIONALLY — until the requested
        // user-assigned-device-name entitlement is granted this returns the
        // generic "Apple Watch" (accepted and expected); the grant upgrades
        // the value in place with no code change. See DeviceIdentity.
        DeviceIdentity.deviceName = WKInterfaceDevice.current().name

        isTestEnvironment = WatchStoreBootstrap.isTestEnvironment()
        let defaults: UserDefaults
        if isTestEnvironment, let testDefaults = UserDefaults(suiteName: "ui-testing") {
            testDefaults.removePersistentDomain(forName: "ui-testing")
            defaults = testDefaults
        } else {
            defaults = .standard
        }
        let shouldSync = WatchStoreBootstrap.shouldSync(
            defaults: defaults, isTestEnvironment: isTestEnvironment
        )
        (container, _) = WatchStoreBootstrap.makeContainer(
            syncEnabled: shouldSync, inMemory: isTestEnvironment
        )

        // TEST HARNESS ONLY: production watch installs never seed (questions
        // arrive via sync — see the type doc above); a test launch gets the
        // deterministic default set so watch UI flows have rows to exercise
        // against the in-memory store.
        if isTestEnvironment {
            _ = try? DefaultQuestions.seedIfEmpty(into: ModelContext(container))
        }

        // Forwarded-notification action handling (plan 19 Task 5). Setting
        // the delegate is NOT scheduling: the watch never calls add()/
        // requestAuthorization()/setNotificationCategories() — scheduling
        // authority stays 100% phone-side (see WatchNotificationDelegate).
        let delegate = WatchNotificationDelegate(container: container)
        notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .onChange(of: scenePhase) { _, newPhase in
                    // Foreground poke (plan 19 Task 5): sync may have
                    // changed the shared store while the complications had
                    // no reason to refresh — same pattern as the phone.
                    if newPhase == .active {
                        WatchWidgetRefresher.reload()
                    }
                }
        }
        .modelContainer(container)
    }
}
