import DispatchKit
import SwiftUI

struct SettingsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(NotificationScheduler.self) private var scheduler
    @Environment(AppLockStore.self) private var appLockStore
    @Environment(\.notificationPrefs) private var notificationPrefs
    @Environment(\.appDefaults) private var appDefaults
    @State private var nextAlertCaption: String?

    private var theme: Theme { themeStore.theme }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                scheduleSection
                surveySection
                privacySection
                dataSection
                interfaceSection
                aboutSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear(perform: refreshNextAlertCaption)
    }

    private func refreshNextAlertCaption() {
        scheduler.nextPromptDate { date in
            Task { @MainActor in
                guard let date else {
                    nextAlertCaption = nil
                    return
                }
                nextAlertCaption = "Next alert at: \(Self.timeFormatter.string(from: date))"
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    // MARK: - Sections

    private var scheduleSection: some View {
        Section {
            NavigationLink(destination: NotificationSettingsView(prefs: notificationPrefs)) {
                HStack {
                    settingsLabel("Notifications")
                    Spacer()
                    if let nextAlertCaption {
                        Text(nextAlertCaption)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .accessibilityIdentifier("notifications-settings-link")
            .listRowBackground(Color.white.opacity(0.12))

            NavigationLink(destination: PromptGroupsView()) {
                settingsLabel("Prompt Groups")
            }
            .accessibilityIdentifier("prompt-groups-link")
            .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("SCHEDULE")
        }
    }

    private var surveySection: some View {
        Section {
            NavigationLink(destination: QuestionSettingsView()) {
                settingsLabel("Questions")
            }
            .listRowBackground(Color.white.opacity(0.12))
            .accessibilityIdentifier("questions-settings-link")

            NavigationLink(destination: CustomTokensView()) {
                settingsLabel("Custom Tokens")
            }
            .listRowBackground(Color.white.opacity(0.12))

            NavigationLink(destination: SensorSettingsView(defaults: appDefaults)) {
                settingsLabel("Sensors")
            }
            .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("SURVEY")
        }
    }

    private var privacySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { appLockStore.enabled },
                set: { newValue in
                    Task { await appLockStore.setEnabled(newValue) }
                })) {
                settingsLabel("Require Face ID")
            }
            .tint(ThemeColor.color(theme))
            .accessibilityIdentifier("app-lock-toggle")
            .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("PRIVACY")
        }
    }

    private var dataSection: some View {
        Section {
            NavigationLink(destination: DataSettingsView()) {
                settingsLabel("Import & Export")
            }
            .listRowBackground(Color.white.opacity(0.12))
            .accessibilityIdentifier("data-settings-link")

            NavigationLink(destination: Text("Coming soon")) {
                settingsLabel("iCloud")
            }
            .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("DATA")
        }
    }

    private var interfaceSection: some View {
        Section {
            HStack(spacing: 12) {
                ForEach(Theme.allCases, id: \.rawValue) { candidate in
                    themeSwatch(candidate)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("INTERFACE")
        }
    }

    private func themeSwatch(_ candidate: Theme) -> some View {
        Button {
            themeStore.theme = candidate
        } label: {
            Capsule()
                .fill(ThemeColor.color(candidate))
                .frame(height: 36)
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 1)
                }
                .overlay {
                    if candidate == theme {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.displayName)
        .accessibilityAddTraits(candidate == theme ? .isSelected : [])
    }

    private var aboutSection: some View {
        Section {
            HStack {
                settingsLabel("Dispatch")
                Spacer()
                Text(appVersion)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .listRowBackground(Color.white.opacity(0.12))

            Text("A self-reporting survey app carrying the torch of Reporter, the discontinued original that inspired it.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
                .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("ABOUT")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    // MARK: - Shared styling

    private func settingsLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.white)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }
}
