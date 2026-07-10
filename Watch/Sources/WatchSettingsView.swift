import DispatchKit
import SwiftUI

/// Watch settings (plan 19 v1): a sync-status line + sensor toggles for the
/// watch-capable set only. `SensorSettings` is UserDefaults-backed and
/// therefore PER-DEVICE — these toggles are the watch's own (default ON) and
/// never sync to the phone (cross-device toggle sync is deferred scope).
struct WatchSettingsView: View {
    private let settings = SensorSettings()
    @State private var enabledByKind: [SensorKind: Bool]

    init() {
        let settings = SensorSettings()
        var initial: [SensorKind: Bool] = [:]
        for kind in WatchProviders.watchCapableKinds {
            initial[kind] = settings.isEnabled(kind)
        }
        _enabledByKind = State(initialValue: initial)
    }

    /// Mirrors the watch bootstrap's launch decision for display: the toggle
    /// is read from the watch's own defaults (absent = ON), and container
    /// mode was decided at launch — relaunch semantics, same as the phone.
    private var syncStatusLine: String {
        let isTest = WatchStoreBootstrap.isTestEnvironment()
        let enabled = !isTest
            && (UserDefaults.standard.object(forKey: WatchStoreBootstrap.syncEnabledKey) as? Bool ?? true)
        return enabled ? "iCloud Sync: On" : "iCloud Sync: Off"
    }

    var body: some View {
        List {
            Section {
                Label(syncStatusLine, systemImage: "icloud")
                    .accessibilityIdentifier("watch-sync-status")
            } header: {
                Text("Sync")
            } footer: {
                Text("Questions and reports sync through iCloud. Manage sync on your iPhone.")
            }
            Section {
                ForEach(WatchProviders.watchCapableKinds, id: \.self) { kind in
                    Toggle(kind.watchDisplayName, isOn: enabledBinding(kind))
                }
            } header: {
                Text("Sensors")
            } footer: {
                Text("Sensor toggles are per-device. Other sensors are captured by your iPhone only.")
            }
        }
        .navigationTitle("Settings")
    }

    private func enabledBinding(_ kind: SensorKind) -> Binding<Bool> {
        Binding(
            get: { enabledByKind[kind] ?? true },
            set: { newValue in
                enabledByKind[kind] = newValue
                settings.setEnabled(kind, newValue)
            }
        )
    }
}
