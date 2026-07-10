import DispatchKit
import SwiftData
import SwiftUI
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
    let container: ModelContainer
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
    }

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
        }
        .modelContainer(container)
    }
}
