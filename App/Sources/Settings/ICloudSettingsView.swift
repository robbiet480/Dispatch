import CloudKit
import DispatchKit
import SwiftUI

/// iCloud Sync settings: the sync toggle (relaunch semantics — the container
/// is chosen at launch), the account status, and the last observed sync
/// activity. The CloudKit account-status lookup runs in a `.task` — never a
/// blocking CloudKit call on the main thread.
struct ICloudSettingsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(RemoteChangeObserver.self) private var remoteChangeObserver
    @Environment(BackupManager.self) private var backupManager
    @Environment(\.appDefaults) private var appDefaults

    @State private var syncEnabled = true
    @State private var accountStatusText = "—"
    @State private var hasLoadedToggle = false

    private var theme: Theme { themeStore.theme }

    private var policy: SyncPolicy {
        SyncPolicy(
            defaults: appDefaults,
            isTestEnvironment: ProcessInfo.processInfo.arguments.contains("--mock-sensors")
                || ProcessInfo.processInfo.arguments.contains("--ui-testing")
        )
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                Section {
                    Toggle(isOn: $syncEnabled) {
                        settingsLabel("iCloud Sync")
                    }
                    .tint(ThemeColor.color(theme))
                    .accessibilityIdentifier("icloud-sync-toggle")
                    .listRowBackground(Color.white.opacity(0.12))
                    .onChange(of: syncEnabled) { _, newValue in
                        guard hasLoadedToggle else { return }
                        policy.userPreference = newValue
                    }
                } header: {
                    sectionHeader("SYNC")
                } footer: {
                    Text("Takes effect after reopening Dispatch.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .listRowBackground(Color.clear)
                }

                Section {
                    HStack {
                        settingsLabel("Account")
                        Spacer()
                        Text(accountStatusText)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .listRowBackground(Color.white.opacity(0.12))

                    HStack {
                        settingsLabel("Last sync activity")
                        Spacer()
                        Text(lastActivityText)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                } header: {
                    sectionHeader("STATUS")
                }

                // Manual backup (same shared BackupManager action as
                // Settings → Data's button — one trigger, two surfaces).
                // Manual backups bypass the first-launch auto-backup guard
                // by design: an explicit request is explicit consent.
                Section {
                    Button {
                        backupManager.backUpNow()
                    } label: {
                        if backupManager.isBackingUp {
                            HStack {
                                settingsLabel("Back Up Now")
                                Spacer()
                                ProgressView()
                                    .tint(.white)
                            }
                        } else {
                            settingsLabel("Back Up Now")
                        }
                    }
                    .accessibilityIdentifier("backup-now-icloud")
                    .disabled(backupManager.isBackingUp)
                    .listRowBackground(Color.white.opacity(0.12))
                } header: {
                    sectionHeader("BACKUP")
                } footer: {
                    Text(backupCaption)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityIdentifier("backup-caption-icloud")
                        .listRowBackground(Color.clear)
                }

                Section {
                    Text("Reports, questions, prompt groups, and vocabulary sync through your private iCloud database. Nothing is shared or public.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .listRowBackground(Color.white.opacity(0.12))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Plan 27: readable column on iPad; no-op at iPhone widths.
            .readableColumn()
        }
        .navigationTitle("iCloud")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            syncEnabled = policy.userPreference
            hasLoadedToggle = true
        }
        .task {
            await loadAccountStatus()
        }
    }

    /// Condensed version of the Data screen's backup caption: last-backup
    /// line plus the iCloud unavailable/failed status lines it shows.
    private var backupCaption: String {
        var lines = [String]()
        if let last = backupManager.lastBackupDate {
            lines.append("Last backup: \(last.formatted(date: .abbreviated, time: .shortened)).")
        } else {
            lines.append("No backups yet.")
        }
        switch backupManager.iCloudAvailability {
        case .some(false) where backupManager.destination != .local:
            lines.append("iCloud Drive unavailable — backups stay on this device.")
        case .some(true) where backupManager.lastICloudBackupFailed:
            lines.append("Last iCloud Drive backup failed (check your iCloud storage) — the local copy is unaffected.")
        default:
            break
        }
        return lines.joined(separator: " ")
    }

    private var lastActivityText: String {
        guard let date = remoteChangeObserver.lastEventDate else { return "—" }
        return Self.activityFormatter.string(from: date)
    }

    private static let activityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func loadAccountStatus() async {
        do {
            let status = try await CKContainer(identifier: SyncPolicy.containerIdentifier).accountStatus()
            accountStatusText = Self.text(for: status)
        } catch {
            syncLog.error("account status lookup failed: \(error, privacy: .public)")
            accountStatusText = "Unavailable"
        }
    }

    private static func text(for status: CKAccountStatus) -> String {
        switch status {
        case .available: "Available"
        case .noAccount: "No iCloud account"
        case .restricted: "Restricted"
        case .couldNotDetermine: "Unknown"
        case .temporarilyUnavailable: "Temporarily unavailable"
        @unknown default: "Unknown"
        }
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
