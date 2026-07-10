import CloudKit
import DispatchKit
import SwiftData
import SwiftUI

/// Plan 37 — Settings → iCloud → Diagnostics.
///
/// A read-only evidence screen: account status, a timeline of observed sync
/// events, lifetime dedupe merge counts, per-device report provenance, and a
/// privacy-safe export. HONEST throughout — it shows only observed facts (no
/// spinner, no "Syncing…", no percent). When sync is on and iCloud reachable
/// but nothing has been observed this session, it says exactly that rather
/// than inferring progress or trouble.
struct SyncDiagnosticsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(SyncDiagnostics.self) private var diagnostics
    @Environment(\.appDefaults) private var appDefaults
    @Query private var reports: [Report]

    @State private var accountStatusText = "—"
    @State private var accountIsAvailable = false

    private var theme: Theme { themeStore.theme }

    private var isTestEnvironment: Bool {
        ProcessInfo.processInfo.arguments.contains("--mock-sensors")
            || ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    private var syncEnabled: Bool {
        SyncPolicy(defaults: appDefaults, isTestEnvironment: isTestEnvironment).userPreference
    }

    private var provenance: [(label: String, count: Int)] {
        DeviceProvenance.breakdown(
            reports.map { (name: $0.sourceDeviceName, model: $0.sourceDeviceModel) }
        )
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                statusSection
                eventsSection
                dedupeSection
                devicesSection
                exportSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .readableColumn()
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            await loadAccountStatus()
        }
    }

    // MARK: - Status

    @ViewBuilder private var statusSection: some View {
        Section {
            row("iCloud Sync", value: syncEnabled ? "On" : "Off")
            row("Effective", value: diagnostics.isSyncActive ? "Active" : "Local only")
            row("Account", value: accountStatusText)
            if let export = diagnostics.lastCloudKitExport {
                resultRow("Last iCloud export", date: export.date, succeeded: export.succeeded)
            }
            if let importResult = diagnostics.lastCloudKitImport {
                resultRow("Last iCloud import", date: importResult.date, succeeded: importResult.succeeded)
            }
        } header: {
            sectionHeader("STATUS")
        } footer: {
            if let stall = stallSentence {
                footnote(stall)
                    .accessibilityIdentifier("sync-diagnostics-stall")
            }
        }
    }

    /// The stall surfacing (honesty decision): a fact-conjunction, not an
    /// inference. Only when sync is on, iCloud is reachable, and NO sync
    /// events have been observed since launch.
    private var stallSentence: String? {
        guard diagnostics.isSyncActive, accountIsAvailable, diagnostics.events.isEmpty else {
            return nil
        }
        return "Sync is on and iCloud is reachable, but no sync events have been observed since launch. First-launch backfill and quiet stores are normal."
    }

    // MARK: - Events

    @ViewBuilder private var eventsSection: some View {
        Section {
            if diagnostics.events.isEmpty {
                Text("No sync events observed yet")
                    .foregroundStyle(.white.opacity(0.6))
                    .listRowBackground(Color.white.opacity(0.12))
                    .accessibilityIdentifier("sync-diagnostics-events-empty")
            } else {
                ForEach(Array(diagnostics.events.enumerated()), id: \.offset) { _, event in
                    eventRow(event)
                }
            }
        } header: {
            sectionHeader("EVENTS")
        }
    }

    @ViewBuilder private func eventRow(_ event: SyncEventRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                // No color-only signaling (plan 17): symbol + text.
                if let succeeded = event.succeeded {
                    Image(systemName: succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(.white.opacity(0.8))
                        .accessibilityHidden(true)
                }
                Text(event.kind?.displayName ?? event.kindRaw)
                    .foregroundStyle(.white)
                Spacer()
                Text(event.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            if let detail = event.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .listRowBackground(Color.white.opacity(0.12))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Dedupe

    @ViewBuilder private var dedupeSection: some View {
        let totals = diagnostics.dedupeTotals
        Section {
            row("Questions", value: "\(totals.questions)")
            row("Prompt groups", value: "\(totals.promptGroups)")
            row("Vocabulary tokens", value: "\(totals.tokens)")
            row("People", value: "\(totals.people)")
            row("Reports", value: "\(totals.reports)")
            if let last = totals.lastPassDate {
                HStack {
                    settingsLabel("Last pass")
                    Spacer()
                    Text(last, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .listRowBackground(Color.white.opacity(0.12))
            }
        } header: {
            sectionHeader("DEDUPE")
        } footer: {
            footnote("Merges are the normal resolution of duplicate rows that cross-device sync can create — the same record arriving twice is collapsed into one.")
        }
    }

    // MARK: - Devices

    @ViewBuilder private var devicesSection: some View {
        Section {
            if provenance.isEmpty {
                Text("No reports yet")
                    .foregroundStyle(.white.opacity(0.6))
                    .listRowBackground(Color.white.opacity(0.12))
            } else {
                ForEach(provenance, id: \.label) { entry in
                    row(entry.label, value: "\(entry.count)")
                }
            }
        } header: {
            sectionHeader("DEVICES")
        } footer: {
            footnote("Reports grouped by the device that filed them. \"Unknown device\" means the report was filed before device tracking was added.")
        }
    }

    // MARK: - Export

    @ViewBuilder private var exportSection: some View {
        Section {
            ShareLink(
                item: renderedReport(),
                preview: SharePreview("Dispatch sync diagnostics")
            ) {
                settingsLabel("Export Diagnostics")
            }
            .accessibilityIdentifier("sync-diagnostics-export")
            .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("EXPORT")
        } footer: {
            footnote("Contains sync activity and device counts only — never your reports, answers, or health data.")
        }
    }

    private func renderedReport() -> String {
        SyncDiagnosticsReport.render(
            appVersion: appVersionString,
            osVersion: osVersionString,
            deviceModel: DeviceIdentity.model ?? "Unknown",
            syncEnabled: syncEnabled,
            syncActive: diagnostics.isSyncActive,
            accountStatusText: accountStatusText,
            events: diagnostics.events,
            dedupeTotals: diagnostics.dedupeTotals,
            provenance: provenance,
            generatedAt: Date()
        )
    }

    private var appVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    private var osVersionString: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    // MARK: - Account status

    private func loadAccountStatus() async {
        // Under test the account row stays "—" and no CloudKit call is made
        // (the diagnostics view must render offline for the navigation test).
        guard !isTestEnvironment else { return }
        do {
            let status = try await CKContainer(identifier: SyncPolicy.containerIdentifier).accountStatus()
            accountStatusText = Self.text(for: status)
            accountIsAvailable = status == .available
        } catch {
            syncLog.error("account status lookup failed: \(error, privacy: .public)")
            accountStatusText = "Unavailable"
            accountIsAvailable = false
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

    private func row(_ title: String, value: String) -> some View {
        HStack {
            settingsLabel(title)
            Spacer()
            Text(value)
                .foregroundStyle(.white.opacity(0.7))
        }
        .listRowBackground(Color.white.opacity(0.12))
    }

    private func resultRow(_ title: String, date: Date, succeeded: Bool) -> some View {
        HStack {
            Image(systemName: succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityHidden(true)
            settingsLabel(title)
            Spacer()
            Text("\(succeeded ? "OK" : "Failed") · \(date.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .listRowBackground(Color.white.opacity(0.12))
        .accessibilityElement(children: .combine)
    }

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

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.6))
            .listRowBackground(Color.clear)
    }
}
