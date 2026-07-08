import DispatchKit
import SwiftUI

struct SensorSettingsView: View {
    @State private var settings: SensorSettings
    @State private var temperatureUnit: TemperatureUnit
    @State private var lengthUnit: LengthUnit
    @State private var enabledByKind: [SensorKind: Bool]
    @State private var isRequestingPermissions = false
    @Environment(ThemeStore.self) private var themeStore
    @Environment(PermissionCascade.self) private var permissionCascade

    private var theme: Theme { themeStore.theme }

    init(defaults: UserDefaults) {
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
                        Toggle(kind.displayName, isOn: enabledBinding(kind))
                            .tint(.white.opacity(0.4))
                            .foregroundStyle(.white)
                    }

                    Button {
                        Task { await requestSensorAccess() }
                    } label: {
                        HStack {
                            Text("Request Sensor Access…")
                            Spacer()
                            if isRequestingPermissions {
                                ProgressView()
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .disabled(isRequestingPermissions)
                    .accessibilityIdentifier("request-sensor-access")
                } header: {
                    sectionHeader("SENSORS")
                }
                .listRowBackground(Color.white.opacity(0.12))

                Section {
                    Picker("Temperature", selection: $temperatureUnit) {
                        Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
                        Text("Celsius").tag(TemperatureUnit.celsius)
                    }
                    .onChange(of: temperatureUnit) { _, newValue in
                        settings.temperatureUnit = newValue
                    }

                    Picker("Length", selection: $lengthUnit) {
                        Text("Feet").tag(LengthUnit.feet)
                        Text("Meters").tag(LengthUnit.meters)
                    }
                    .onChange(of: lengthUnit) { _, newValue in
                        settings.lengthUnit = newValue
                    }
                } header: {
                    sectionHeader("UNITS")
                }
                .listRowBackground(Color.white.opacity(0.12))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Sensors")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func requestSensorAccess() async {
        guard !isRequestingPermissions else { return }
        isRequestingPermissions = true
        await permissionCascade.requestAll()
        isRequestingPermissions = false
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
        case .healthFlights: "Stairs Climbed"
        case .healthHeart: "Heart Rate"
        case .healthHRV: "HRV"
        case .healthRestingHeart: "Resting Heart Rate"
        case .healthSleep: "Sleep"
        case .healthWorkouts: "Workouts"
        case .healthCaffeine: "Caffeine"
        case .healthMedications: "Medications"
        case .healthActivityRings: "Activity Rings"
        }
    }
}
