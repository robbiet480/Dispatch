import DispatchKit
import SwiftUI

struct SettingsView: View {
    @Environment(ThemeStore.self) private var themeStore

    private var theme: Theme { themeStore.theme }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                scheduleSection
                surveySection
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
    }

    // MARK: - Sections

    private var scheduleSection: some View {
        Section {
            NavigationLink(destination: Text("Coming in Plan 4")) {
                settingsLabel("Notifications")
            }
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

            NavigationLink(destination: SensorSettingsView()) {
                settingsLabel("Sensors")
            }
            .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("SURVEY")
        }
    }

    private var dataSection: some View {
        Section {
            NavigationLink(destination: Text("Coming soon")) {
                settingsLabel("Export")
            }
            .listRowBackground(Color.white.opacity(0.12))

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
