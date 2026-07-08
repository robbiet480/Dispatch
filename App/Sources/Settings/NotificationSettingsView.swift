import DispatchKit
import SwiftUI

/// Notification settings screen: mirrors the original Reporter "Schedule"
/// screen — next-alert readout, alerts-per-day stepper, distribution
/// picker, and a list of fixed scheduled times. All mutations write
/// through `NotificationPrefs` (backed by the environment's isolated
/// `appDefaults` suite) and immediately trigger a re-plan via the
/// environment-provided `NotificationScheduler`.
struct NotificationSettingsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(AwakeStore.self) private var awakeStore
    @Environment(NotificationScheduler.self) private var scheduler
    @Environment(\.notificationPrefs) private var prefs

    @State private var alertsPerDay: Int
    @State private var distribution: PromptDistribution
    @State private var scheduledTimes: [DateComponents]
    @State private var nextAlertText: String = "—"
    @State private var isAddingTime = false
    @State private var newTimeSelection = Date()

    private var theme: Theme { themeStore.theme }

    init(prefs: NotificationPrefs) {
        _alertsPerDay = State(initialValue: prefs.alertsPerDay)
        _distribution = State(initialValue: prefs.distribution)
        _scheduledTimes = State(initialValue: prefs.scheduledTimes)
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                nextNotificationSection
                frequencySection
                distributionSection
                scheduledSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear(perform: refreshNextAlert)
        .sheet(isPresented: $isAddingTime) {
            addTimeSheet
        }
    }

    // MARK: - Sections

    private var nextNotificationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(nextAlertText)
                    .font(.system(size: 40, weight: .light, design: .rounded))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("next-notification-time")
                Text("FROM DISTRIBUTION")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
            .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("NEXT NOTIFICATION")
        }
    }

    private var frequencySection: some View {
        Section {
            HStack {
                Text("Alerts per Day")
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    updateAlertsPerDay(alertsPerDay - 1)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .disabled(alertsPerDay <= 1)
                .accessibilityIdentifier("alerts-per-day-decrement")

                Text("\(alertsPerDay)")
                    .frame(minWidth: 24)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("alerts-per-day-count")

                Button {
                    updateAlertsPerDay(alertsPerDay + 1)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .disabled(alertsPerDay >= 12)
                .accessibilityIdentifier("alerts-per-day-increment")
            }
            .foregroundStyle(.white)
            .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("FREQUENCY")
        }
    }

    private var distributionSection: some View {
        Section {
            ForEach(PromptDistribution.allCases, id: \.self) { candidate in
                Button {
                    updateDistribution(candidate)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                            Text(candidate.description(alertsPerDay: alertsPerDay))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                        if distribution == candidate {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.white)
                        }
                    }
                }
                .accessibilityIdentifier("distribution-\(candidate.rawValue)")
                .listRowBackground(Color.white.opacity(0.12))
            }
        } header: {
            sectionHeader("DISTRIBUTION")
        }
    }

    private var scheduledSection: some View {
        Section {
            ForEach(sortedScheduledTimes, id: \.self) { components in
                Text(formattedTime(components))
                    .foregroundStyle(.white)
                    .listRowBackground(Color.white.opacity(0.12))
            }
            .onDelete(perform: deleteScheduledTimes)

            Button {
                newTimeSelection = Date()
                isAddingTime = true
            } label: {
                Text("ADD A NOTIFICATION TIME…")
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("add-notification-time")
            .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("SCHEDULED")
        }
    }

    private var addTimeSheet: some View {
        NavigationStack {
            ZStack {
                Color.themeBackground(theme)
                    .ignoresSafeArea()

                DatePicker(
                    "Time",
                    selection: $newTimeSelection,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .colorScheme(.dark)
                .padding()
            }
            .navigationTitle("New Notification Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isAddingTime = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addScheduledTime(newTimeSelection)
                        isAddingTime = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Mutations

    private func updateAlertsPerDay(_ value: Int) {
        let clamped = max(1, min(12, value))
        alertsPerDay = clamped
        prefs.alertsPerDay = clamped
        replan()
    }

    private func updateDistribution(_ value: PromptDistribution) {
        distribution = value
        prefs.distribution = value
        replan()
    }

    private func addScheduledTime(_ date: Date) {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        var updated = scheduledTimes
        updated.append(components)
        scheduledTimes = updated
        prefs.scheduledTimes = updated
        replan()
    }

    private func deleteScheduledTimes(at offsets: IndexSet) {
        var sorted = sortedScheduledTimes
        sorted.remove(atOffsets: offsets)
        scheduledTimes = sorted
        prefs.scheduledTimes = sorted
        replan()
    }

    private func replan() {
        scheduler.replan(prefs: prefs, awakeStore: awakeStore)
        refreshNextAlert()
    }

    private func refreshNextAlert() {
        scheduler.nextPromptDate { date in
            Task { @MainActor in
                guard let date else {
                    nextAlertText = "—"
                    return
                }
                nextAlertText = Self.timeFormatter.string(from: date)
            }
        }
    }

    // MARK: - Helpers

    private var sortedScheduledTimes: [DateComponents] {
        scheduledTimes.sorted { lhs, rhs in
            let lhsMinutes = (lhs.hour ?? 0) * 60 + (lhs.minute ?? 0)
            let rhsMinutes = (rhs.hour ?? 0) * 60 + (rhs.minute ?? 0)
            return lhsMinutes < rhsMinutes
        }
    }

    private func formattedTime(_ components: DateComponents) -> String {
        String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }
}

private extension PromptDistribution {
    var title: String {
        switch self {
        case .random: "Random"
        case .semiRandom: "Semi-random"
        case .regular: "Regular"
        }
    }
}
