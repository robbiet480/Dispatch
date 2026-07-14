import CloudKit
import DispatchKit
import SwiftUI

/// Settings → Sync: the iCloud sync toggle (relaunch semantics — the container
/// is chosen at launch), the CloudKit account status, the last observed store
/// change, and a manual "Back Up Now".
///
/// Diagnostics (a Mac-native equivalent of the iOS `SyncDiagnosticsView`) is
/// deliberately absent — tracked by issue #103, deferred rather than stubbed.
struct SyncSettingsPane: View {
    @Environment(RemoteChangeObserver.self) private var remoteChangeObserver
    @Environment(BackupManager.self) private var backupManager
    @Environment(\.appDefaults) private var appDefaults

    @State private var syncEnabled = true
    @State private var hasLoadedToggle = false
    @State private var accountStatusText = "—"

    private var isTestEnvironment: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--mock-sensors") || arguments.contains("--ui-testing")
    }

    private var policy: SyncPolicy {
        SyncPolicy(defaults: appDefaults, isTestEnvironment: isTestEnvironment)
    }

    var body: some View {
        Form {
            Section {
                Toggle("iCloud Sync", isOn: $syncEnabled)
                    .accessibilityIdentifier("icloud-sync-toggle")
                    // The toggle is seeded from the policy in `.onAppear`;
                    // `hasLoadedToggle` keeps that seeding pass from writing
                    // the preference straight back through `onChange`.
                    .onChange(of: syncEnabled) { _, newValue in
                        guard hasLoadedToggle else { return }
                        policy.userPreference = newValue
                    }
                LabeledContent("iCloud Account", value: accountStatusText)
                    .accessibilityIdentifier("icloud-account-status")
                // Plan 37 honesty relabel: this timestamp is when a store
                // change was OBSERVED, not proof of a successful CloudKit sync.
                LabeledContent("Last store change observed", value: lastActivityText)
            } header: {
                Text("iCloud")
            } footer: {
                Text("Takes effect after reopening Dispatch. Reports filed on your iPhone or Apple Watch sync here through your private iCloud database.")
            }

            Section {
                Button("Back Up Now") { backupManager.backUpNow() }
                    .accessibilityIdentifier("backup-now")
                    .disabled(backupManager.isBackingUp)
            } header: {
                Text("Backups")
            } footer: {
                Text(backupCaption)
                    .accessibilityIdentifier("backup-caption")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500)
        .onAppear {
            syncEnabled = policy.userPreference
            hasLoadedToggle = true
        }
        .task { await loadAccountStatus() }
    }

    /// Honest about WHERE the files land: the sandboxed app container's
    /// Documents directory, which is NOT the user's `~/Documents` and is not
    /// something we can point them at in the Finder — so don't promise a
    /// folder they can open.
    private var backupCaption: String {
        var lines = [String]()
        if let last = backupManager.lastBackupDate {
            lines.append("Last backup: \(last.formatted(date: .abbreviated, time: .shortened)).")
        } else {
            lines.append("No backups yet.")
        }
        if let retention = BackupRotation.retentionCaption(count: backupManager.backupCount) {
            lines.append(retention)
        }
        lines.append("Backups are JSON exports stored inside Dispatch's own app container. "
            + "iCloud sync is not a backup — sync propagates deletions; backups let you rewind.")
        return lines.joined(separator: " ")
    }

    private var lastActivityText: String {
        guard let date = remoteChangeObserver.lastEventDate else { return "None this session" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Never a blocking CloudKit call on the main thread — and never any
    /// CloudKit call at all under test, where there is no account to ask
    /// about and the lookup would only add flake.
    private func loadAccountStatus() async {
        guard !isTestEnvironment else { return }
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
}
