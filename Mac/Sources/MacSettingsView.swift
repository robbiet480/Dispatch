import DispatchKit
import SwiftUI

/// The Settings scene (⌘,) — plan 36's deliberate subset: iCloud sync
/// toggle (shared SyncPolicy, relaunch semantics), theme color, data
/// import/export, About. Notifications, prompt groups, app lock, webhooks,
/// backups scheduling, and health are capture-adjacent or iOS-only and are
/// v1 non-goals, not oversights.
struct MacSettingsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(RemoteChangeObserver.self) private var remoteChangeObserver
    @Environment(MacExportController.self) private var exportController
    @Environment(\.appDefaults) private var appDefaults

    @State private var syncEnabled = true
    @State private var hasLoadedToggle = false

    private var policy: SyncPolicy {
        SyncPolicy(
            defaults: appDefaults,
            isTestEnvironment: ProcessInfo.processInfo.arguments.contains("--mock-sensors")
                || ProcessInfo.processInfo.arguments.contains("--ui-testing")
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("iCloud Sync", isOn: $syncEnabled)
                    .accessibilityIdentifier("icloud-sync-toggle")
                    .onChange(of: syncEnabled) { _, newValue in
                        guard hasLoadedToggle else { return }
                        policy.userPreference = newValue
                    }
                LabeledContent("Last store change observed", value: lastActivityText)
            } header: {
                Text("Sync")
            } footer: {
                Text("Takes effect after reopening Dispatch. Reports filed on your iPhone or Apple Watch sync here through your private iCloud database.")
            }

            Section("Theme") {
                Picker("Theme Color", selection: Binding(
                    get: { themeStore.theme },
                    set: { themeStore.theme = $0 }
                )) {
                    ForEach(Theme.allCases, id: \.self) { theme in
                        HStack {
                            Circle()
                                .fill(ThemeColor.color(theme))
                                .frame(width: 12, height: 12)
                            Text(theme.displayName)
                        }
                        .tag(theme)
                    }
                }
                .accessibilityIdentifier("theme-picker")
            }

            Section {
                LabeledContent("Import Reporter/Dispatch JSON") {
                    Button("Import…") { exportController.importJSON() }
                        .disabled(exportController.isImportRunning)
                }
                LabeledContent("Export") {
                    HStack {
                        Button("Day One JSON…") { exportController.exportDayOne() }
                        Button("Markdown Folder…") { exportController.exportMarkdown() }
                    }
                }
                LabeledContent("") {
                    HStack {
                        Button("Dispatch JSON…") { exportController.exportDispatchJSON() }
                        Button("CSV…") { exportController.exportCSV() }
                    }
                }
            } header: {
                Text("Data")
            } footer: {
                Text("Everything also lives in the File menu. Capture stays on iPhone and Apple Watch — the Mac app is for reviewing, analyzing, and exporting.")
            }

            Section("About") {
                LabeledContent("Version", value: versionText)
                LabeledContent("Sync container", value: SyncPolicy.containerIdentifier)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            syncEnabled = policy.userPreference
            hasLoadedToggle = true
        }
        // The Settings window is its own scene — it needs its own alert
        // surface for import/export results triggered from here.
        .alert("Dispatch", isPresented: Binding(
            get: { exportController.isShowingMessage },
            set: { exportController.isShowingMessage = $0 }
        ), presenting: exportController.message) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    private var lastActivityText: String {
        guard let date = remoteChangeObserver.lastEventDate else { return "None this session" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
