import DispatchKit
import SwiftUI
import UIKit

struct SensorSettingsView: View {
    @State private var settings: SensorSettings
    @State private var temperatureUnit: TemperatureUnit
    @State private var lengthUnit: LengthUnit
    @State private var enabledByKind: [SensorKind: Bool]
    @State private var isRequestingPermissions = false
    @State private var contactSuggestionsEnabled: Bool
    /// Real framework authorization states, refreshed onAppear and whenever
    /// the scene reactivates (returning from the Settings app after fixing a
    /// denial must update the affordances without leaving the screen).
    @State private var permissionStates: [SensorPermission: SensorPermissionState] = [:]
    @Environment(ThemeStore.self) private var themeStore
    @Environment(PermissionCascade.self) private var permissionCascade
    @Environment(SpotifyController.self) private var spotifyController
    // PLAN-39 TASK 0 PROBE — remove after measurement.
    @Environment(SleepDeliveryProbe.self) private var sleepDeliveryProbe
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private var theme: Theme { themeStore.theme }
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        _contactSuggestionsEnabled = State(
            initialValue: defaults.bool(forKey: ContactSuggestions.enabledKey))
        let settings = SensorSettings(defaults: defaults)
        _settings = State(initialValue: settings)
        _temperatureUnit = State(initialValue: settings.temperatureUnit)
        _lengthUnit = State(initialValue: settings.lengthUnit)
        var initialEnabled: [SensorKind: Bool] = [:]
        for kind in SensorKind.allCases {
            initialEnabled[kind] = settings.isEnabled(kind)
        }
        _enabledByKind = State(initialValue: initialEnabled)
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                Section {
                    ForEach(SensorKind.allCases, id: \.self) { kind in
                        HStack(spacing: 12) {
                            Text(kind.displayName)
                                .foregroundStyle(.white)
                            Spacer()
                            permissionAffordance(for: kind)
                            Toggle(kind.displayName, isOn: enabledBinding(kind))
                                .labelsHidden()
                                .fixedSize()
                                .tint(.white.opacity(0.4))
                        }
                    }

                    // Bulk request lives at the BOTTOM of the section and
                    // only while something is actually requestable — when
                    // every permission is granted or denied there is no
                    // dialog left for the cascade to show (denied can only
                    // be fixed in the Settings app, via the row affordance).
                    if hasRequestablePermissions {
                        Button {
                            Task { await requestSensorAccess() }
                        } label: {
                            HStack {
                                Text("Request All Sensors…")
                                Spacer()
                                if isRequestingPermissions {
                                    ProgressView()
                                }
                            }
                        }
                        .foregroundStyle(.white)
                        .disabled(isRequestingPermissions)
                        .accessibilityIdentifier("request-all-sensors")
                    }
                } header: {
                    sectionHeader("SENSORS")
                }
                .listRowBackground(Color.white.opacity(0.12))

                // Focus filter hint (plan 15): Apple provides no in-app
                // enrollment for Focus Filters, so the best we can do is
                // point at the Settings path. Sits with the Focus sensor's
                // toggle above since the filter is what upgrades that
                // sensor's boolean reading to a named Focus.
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Name your Focus in reports")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("Add the Dispatch filter to a Focus mode to record its name (e.g. \u{201C}Work\u{201D}) and choose which prompt groups can fire while it's on.")
                            .font(.caption)
                            .opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("focus-filter-hint")
                } header: {
                    sectionHeader("FOCUS FILTER")
                } footer: {
                    Text("Set up in the Settings app: Focus → choose a mode → Focus Filters → Add Filter → Dispatch. Apple provides no way to do this from inside an app.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .listRowBackground(Color.clear)
                }
                .listRowBackground(Color.white.opacity(0.12))

                // Media sources (plan 26): the Media toggle itself lives in
                // the SENSORS list above (allCases); this section carries the
                // Spotify connection status + connect/disconnect entry point.
                Section {
                    NavigationLink {
                        SpotifySettingsView()
                    } label: {
                        HStack {
                            Text("Spotify")
                            Spacer()
                            Text(spotifyStatusCaption)
                                .font(.caption)
                                .opacity(0.6)
                        }
                    }
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("spotify-settings-link")
                } header: {
                    sectionHeader("MEDIA")
                } footer: {
                    Text("Apple Music is read automatically when the Media sensor is on. Connect Spotify to record its now-playing track too.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .listRowBackground(Color.white.opacity(0.12))

                // Contacts suggestions (plan 22): default OFF; enabling makes
                // the one standard requestAccess call. Purpose string only,
                // no entitlement. Full-vs-limited access is transparent.
                Section {
                    Toggle("Suggest from Contacts", isOn: contactsBinding)
                        .tint(.white.opacity(0.4))
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("contacts-suggestions-toggle")
                } header: {
                    sectionHeader("CONTACTS")
                } footer: {
                    if contactSuggestionsEnabled && ContactSuggestions.isDenied {
                        Text("Contacts access is denied. Allow it in the Settings app to see contact suggestions.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .accessibilityIdentifier("contacts-denied-hint")
                            .listRowBackground(Color.clear)
                    } else {
                        Text("Shows names and photos from your Contacts when answering people questions. Contact links never leave this device.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .listRowBackground(Color.clear)
                    }
                }
                .listRowBackground(Color.white.opacity(0.12))

                Section {
                    Picker("Temperature", selection: $temperatureUnit) {
                        Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
                        Text("Celsius").tag(TemperatureUnit.celsius)
                    }
                    .foregroundStyle(.white)
                    .tint(.white.opacity(0.7))
                    .onChange(of: temperatureUnit) { _, newValue in
                        settings.temperatureUnit = newValue
                    }

                    Picker("Length", selection: $lengthUnit) {
                        Text("Feet").tag(LengthUnit.feet)
                        Text("Meters").tag(LengthUnit.meters)
                    }
                    .foregroundStyle(.white)
                    .tint(.white.opacity(0.7))
                    .onChange(of: lengthUnit) { _, newValue in
                        settings.lengthUnit = newValue
                    }
                } header: {
                    sectionHeader("UNITS")
                }
                .listRowBackground(Color.white.opacity(0.12))

                // PLAN-39 TASK 0 PROBE — remove after measurement. Diagnostic
                // toggle for the sleepAnalysis delivery-timing spike; the
                // probe registers/unregisters immediately and re-registers on
                // launch while enabled.
                Section {
                    Toggle("Sleep Delivery Probe", isOn: probeBinding)
                        .tint(.white.opacity(0.4))
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("sleep-delivery-probe-toggle")
                } header: {
                    sectionHeader("DIAGNOSTICS")
                } footer: {
                    Text("Temporary diagnostic for measuring Health sleep-data delivery. Logs to Files > Dispatch > sleep-probe.log")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .listRowBackground(Color.clear)
                }
                .listRowBackground(Color.white.opacity(0.12))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Plan 27: readable column on iPad; no-op at iPhone widths.
            .readableColumn()
        }
        .navigationTitle("Sensors")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            await refreshPermissionStates()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Returning from the Settings app (after flipping a denied
            // permission) must refresh the affordances in place.
            guard newPhase == .active else { return }
            Task { await refreshPermissionStates() }
        }
    }

    // MARK: - Permission affordances

    private var statusProvider: SensorPermissionStatusProvider {
        SensorPermissionStatusProvider(isTestEnvironment: permissionCascade.isTestEnvironment)
    }

    private var hasRequestablePermissions: Bool {
        SensorPermission.allCases.contains { permissionStates[$0] == .notDetermined }
    }

    private func refreshPermissionStates() async {
        var states: [SensorPermission: SensorPermissionState] = [:]
        for permission in SensorPermission.allCases {
            states[permission] = await statusProvider.status(for: permission)
        }
        permissionStates = states
    }

    /// Inline trailing affordance reflecting the row's REAL authorization
    /// state: subdued "Granted"/"Requested" text when nothing is actionable,
    /// a "Request" button when the dialog hasn't been shown yet, and a
    /// "Denied" button deep-linking to the Settings app (the only place a
    /// denial can be fixed). Rows without a gating permission — and unknown
    /// states — render nothing.
    @ViewBuilder
    private func permissionAffordance(for kind: SensorKind) -> some View {
        if let permission = kind.permission {
            switch permissionStates[permission] ?? .unknown {
            case .granted, .requested:
                // A filled radio, no text. HealthKit hides read-grant status
                // (see SensorPermissionState), so `.requested` — the dialog
                // was shown, the choice is opaque — can't be distinguished
                // from `.granted`; both are usable and collapse to "on".
                permissionRadio(on: true)
                    .accessibilityIdentifier("permission-radio-\(permission.rawValue)")
                    .accessibilityLabel("Granted")
            case .notDetermined:
                // The only truly requestable state: a Request button plus an
                // empty radio.
                HStack(spacing: 12) {
                    requestButton(permission: permission)
                    permissionRadio(on: false)
                        .accessibilityIdentifier("permission-radio-\(permission.rawValue)")
                        .accessibilityLabel("Not granted")
                }
            case .denied:
                // Empty radio, tappable — a denial can only be reversed in
                // the Settings app, so the indicator deep-links there.
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    permissionRadio(on: false)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("permission-radio-\(permission.rawValue)")
                .accessibilityLabel("Denied — open Settings")
            case .unknown:
                EmptyView()
            }
        }
    }

    /// The status indicator: a filled radio when the permission is usable,
    /// an empty one otherwise. Purely visual — callers attach the identifier
    /// and label so the granted/denied/requestable cases stay distinct.
    private func permissionRadio(on: Bool) -> some View {
        Image(systemName: on ? "largecircle.fill.circle" : "circle")
            .font(.body)
            .foregroundStyle(.white.opacity(on ? 0.9 : 0.4))
    }

    private func requestButton(permission: SensorPermission) -> some View {
        Button {
            Task {
                await permissionCascade.request(permission)
                await refreshPermissionStates()
            }
        } label: {
            Text("Request")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.2), in: Capsule())
        }
        // Borderless keeps the tap target scoped to the capsule — a plain
        // row-embedded Button would otherwise swallow the whole row.
        .buttonStyle(.borderless)
        .disabled(permissionCascade.isRequesting)
        .accessibilityIdentifier("permission-request-\(permission.rawValue)")
    }

    private func requestSensorAccess() async {
        guard !isRequestingPermissions else { return }
        isRequestingPermissions = true
        await permissionCascade.requestAll()
        isRequestingPermissions = false
        await refreshPermissionStates()
    }

    private var contactsBinding: Binding<Bool> {
        Binding(
            get: { contactSuggestionsEnabled },
            set: { newValue in
                contactSuggestionsEnabled = newValue
                defaults.set(newValue, forKey: ContactSuggestions.enabledKey)
                if newValue {
                    // The single standard access request. Stubbed (no dialog)
                    // under --mock-sensors/--ui-testing.
                    Task { _ = await ContactSuggestions.makeProvider().requestAccess() }
                }
            }
        )
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

    // PLAN-39 TASK 0 PROBE — remove after measurement.
    private var probeBinding: Binding<Bool> {
        Binding(
            get: { sleepDeliveryProbe.isEnabled },
            set: { sleepDeliveryProbe.isEnabled = $0 }
        )
    }

    private var spotifyStatusCaption: String {
        if !spotifyController.isConfigured { return "Not configured" }
        return spotifyController.isConnected ? "Connected" : "Not connected"
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }
}

extension SensorKind {
    var displayName: String {
        switch self {
        case .location: "Location"
        case .weather: "Weather"
        case .altitude: "Elevation"
        case .photos: "Photos"
        case .audio: "Audio"
        case .battery: "Battery"
        case .connection: "Connection"
        case .focus: "Focus"
        case .healthSteps: "Steps"
        case .healthFlights: "Stairs"
        case .healthHeart: "Heart Rate"
        case .healthHRV: "HRV"
        case .healthRestingHeart: "Resting Heart Rate"
        case .healthSleep: "Sleep"
        case .healthWorkouts: "Workouts"
        case .healthCaffeine: "Caffeine"
        case .healthMedications: "Medications"
        case .healthActivityRings: "Activity Rings"
        case .media: "Media"
        }
    }
}
