import DispatchKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(NotificationScheduler.self) private var scheduler
    @Environment(AppLockStore.self) private var appLockStore
    @Environment(\.notificationPrefs) private var notificationPrefs
    @Environment(\.appDefaults) private var appDefaults
    @Environment(\.modelContext) private var context
    @State private var nextAlertCaption: String?

    private var theme: Theme { themeStore.theme }

    /// The five panes (Dashboard/Insights/Questions/Groups/Catalog) are
    /// top-level shell tabs on iPad (Task 3.6) and Mac (Task 3.5), so their
    /// Settings rows must not double up here. On iPhone, which has no tab
    /// bar, Settings remains the only way to reach them.
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                if !isPad {
                    manageSection
                }
                scheduleSection
                surveySection
                privacySection
                dataSection
                interfaceSection
                aboutSection
                sourceSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Plan 27: readable column on iPad; no-op at iPhone widths.
            .readableColumn()
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

    /// iPhone only: Questions/Prompt Groups/Catalog are shell tabs on iPad
    /// (Task 3.6) and Mac (Task 3.5), so this section only exists where
    /// there's no tab bar to reach them from. IDs are carried over from
    /// their old homes in `surveySection`/`scheduleSection` so existing
    /// iPhone UI tests keep resolving.
    private var manageSection: some View {
        Section {
            NavigationLink(destination: QuestionSettingsView()) {
                settingsLabel("Questions")
            }
            .listRowBackground(Color.white.opacity(0.12))
            .accessibilityIdentifier("questions-settings-link")

            NavigationLink(destination: PromptGroupsView()) {
                settingsLabel("Prompt Groups")
            }
            .accessibilityIdentifier("prompt-groups-link")
            .listRowBackground(Color.white.opacity(0.12))

            NavigationLink(destination: CatalogView()) {
                settingsLabel("Catalog")
            }
            .accessibilityIdentifier("catalog-settings-link")
            .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("MANAGE")
        }
    }

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

            NavigationLink(destination: BeaconsSettingsView()) {
                settingsLabel("Beacons")
            }
            .accessibilityIdentifier("settings-beacons")
            .listRowBackground(Color.white.opacity(0.12))

            NavigationLink(destination: WeeklyDigestView()) {
                settingsLabel("Weekly Digest")
            }
            .accessibilityIdentifier("weekly-digest-link")
            .listRowBackground(Color.white.opacity(0.12))

            // Insights is a shell tab on iPad (Task 3.6); stays a Settings
            // row on iPhone, which has no tab bar to reach it from.
            if !isPad {
                NavigationLink(destination: InsightsView()) {
                    settingsLabel("Insights")
                }
                .accessibilityIdentifier("insights-link")
                .listRowBackground(Color.white.opacity(0.12))
            }
        } header: {
            sectionHeader("SCHEDULE")
        }
    }

    private var surveySection: some View {
        Section {
            NavigationLink(destination: CustomTokensView()) {
                settingsLabel("Custom Tokens")
            }
            .listRowBackground(Color.white.opacity(0.12))

            NavigationLink(destination: PeopleListView()) {
                settingsLabel("People")
            }
            .listRowBackground(Color.white.opacity(0.12))
            .accessibilityIdentifier("people-settings-link")

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

            // Only meaningful while app lock is on — with lock off, indexing
            // always happens, so the row is hidden entirely (same conditional-
            // row pattern as elsewhere in Settings).
            if appLockStore.enabled {
                Toggle(isOn: Binding(
                    get: { appLockStore.spotlightWhileLockedEnabled },
                    set: { newValue in
                        setSpotlightWhileLocked(newValue)
                    })) {
                    settingsLabel("Spotlight Search While Locked")
                }
                .tint(ThemeColor.color(theme))
                .accessibilityIdentifier("spotlight-while-locked-toggle")
                .listRowBackground(Color.white.opacity(0.12))
            }
        } header: {
            sectionHeader("PRIVACY")
        } footer: {
            if appLockStore.enabled {
                Text("Show reports in iOS search while App Lock is on. Search results can reveal report content without unlocking.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .listRowBackground(Color.clear)
            }
        }
    }

    /// Flipping the opt-in has immediate index side effects: opting in rebuilds
    /// the Spotlight index from all persisted reports (they were deindexed when
    /// app lock came on); opting out re-runs the same wipe that enabling app
    /// lock performs, so nothing stays searchable behind the lock. The rebuild
    /// runs on a background ModelContext off the main actor — same cross-context
    /// pattern as DataSettingsView's import; `SpotlightIndexer.rebuildAll`
    /// snapshots the models before any async work.
    private func setSpotlightWhileLocked(_ newValue: Bool) {
        appLockStore.spotlightWhileLockedEnabled = newValue
        if newValue {
            let container = context.container
            Task.detached(priority: .utility) {
                do {
                    let backgroundContext = ModelContext(container)
                    let reports = try backgroundContext.fetch(FetchDescriptor<Report>())
                    SpotlightIndexer.rebuildAll(reports: reports)
                } catch {
                    // Best-effort, same as every indexer op: the index also
                    // self-heals via index(report:) on each save.
                }
            }
        } else {
            SpotlightIndexer.deleteAll()
        }
    }

    private var dataSection: some View {
        Section {
            NavigationLink(destination: DataSettingsView()) {
                settingsLabel("Import & Export")
            }
            .listRowBackground(Color.white.opacity(0.12))
            .accessibilityIdentifier("data-settings-link")

            NavigationLink(destination: ICloudSettingsView()) {
                settingsLabel("iCloud")
            }
            .accessibilityIdentifier("icloud-settings-link")
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

    private var sourceSection: some View {
        Section {
            Link(destination: Self.repositoryURL) {
                HStack {
                    settingsLabel("View on GitHub")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .accessibilityIdentifier("github-link")
            .listRowBackground(Color.white.opacity(0.12))
        }
    }

    private static let repositoryURL = URL(string: "https://github.com/robbiet480/Dispatch")!

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
