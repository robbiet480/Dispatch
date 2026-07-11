import DispatchKit
import SwiftData
import SwiftUI

/// Settings → Beacons (plan 45, #60): the known iBeacons across enabled
/// beacon-trigger groups, each with a live "in range?" indicator sourced from
/// the observer's last-seen CLMonitor condition state. Read-only — a
/// setup-debugging aid (most people don't know whether their beacon is even
/// being seen). Beacons are configured per group in the Prompt Groups editor.
struct BeaconsSettingsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(MonitorObserver.self) private var monitorObserver
    // Re-read on group changes so a newly-added beacon group appears.
    @Query private var groups: [PromptGroup]

    private var theme: Theme { themeStore.theme }

    var body: some View {
        let beacons = monitorObserver.beacons()
        return ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                if beacons.isEmpty {
                    Text("No beacons yet. Add a beacon trigger to a prompt group "
                        + "(Prompt Groups → “When I'm near a beacon”) and it will "
                        + "appear here with a live in-range indicator for setup.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .listRowBackground(Color.white.opacity(0.12))
                        .accessibilityIdentifier("beacons-empty")
                } else {
                    ForEach(beacons, id: \.id) { beacon in
                        HStack {
                            Text(beacon.name)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer()
                            inRangeLabel(beacon.inRange)
                        }
                        .listRowBackground(Color.white.opacity(0.12))
                        .accessibilityIdentifier("beacon-row")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .readableColumn()
        }
        .navigationTitle("Beacons")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    @ViewBuilder
    private func inRangeLabel(_ inRange: Bool?) -> some View {
        switch inRange {
        case true:
            Text("In range")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .accessibilityIdentifier("beacon-in-range")
        case false:
            Text("Out of range")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityIdentifier("beacon-in-range")
        default:
            Text("Not seen yet")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .accessibilityIdentifier("beacon-in-range")
        }
    }
}
