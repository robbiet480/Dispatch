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
    @State private var nagEnabled: Bool
    @State private var nagDelayMinutes: Int
    @State private var nagIntervalMinutes: Int
    @State private var nagMaxCount: Int
    @State private var digestEnabled: Bool
    @State private var nextAlertText: String = "—"
    @State private var isAddingTime = false
    @State private var newTimeSelection = Date()

    private var theme: Theme { themeStore.theme }

    init(prefs: NotificationPrefs) {
        _alertsPerDay = State(initialValue: prefs.alertsPerDay)
        _distribution = State(initialValue: prefs.distribution)
        _scheduledTimes = State(initialValue: prefs.scheduledTimes)
        _nagEnabled = State(initialValue: prefs.nagEnabled)
        _nagDelayMinutes = State(initialValue: prefs.nagDelayMinutes)
        _nagIntervalMinutes = State(initialValue: prefs.nagIntervalMinutes)
        _nagMaxCount = State(initialValue: prefs.nagMaxCount)
        _digestEnabled = State(initialValue: prefs.digestEnabled)
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                nextNotificationSection
                focusFilterSection
                frequencySection
                distributionSection
                scheduledSection
                nagSection
                digestSection
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

    /// Passive status row (plan 15): visible only while a Dispatch Focus
    /// Filter is active, so the user can tell at a glance why prompts are
    /// quieter than the settings below suggest. Read fresh from the
    /// scheduler on each body evaluation — the row appears/disappears on
    /// navigation, which is enough for a passive indicator.
    @ViewBuilder private var focusFilterSection: some View {
        if let filter = scheduler.activeFocusFilter {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Focus filter: \(filter.label) — \(filter.allowedGroupIDs.count) group\(filter.allowedGroupIDs.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                    Text(filter.allowsGlobal
                         ? "Only these prompt groups are firing; ungrouped prompts continue."
                         : "Only these prompt groups are firing; ungrouped prompts are paused.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .accessibilityIdentifier("focus-filter-status")
                .listRowBackground(Color.white.opacity(0.12))
            } header: {
                sectionHeader("FOCUS FILTER")
            }
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

    private var nagSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { nagEnabled },
                set: { updateNagEnabled($0) }
            )) {
                Text("Persistent Reminders")
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("nag-enabled")
            .listRowBackground(Color.white.opacity(0.12))

            if nagEnabled {
                nagStepperRow(
                    title: "Remind after",
                    value: minutesLabel(minutes: nagDelayMinutes),
                    identifier: "nag-delay",
                    decrementDisabled: nagDelayMinutes <= 1,
                    incrementDisabled: nagDelayMinutes >= 120,
                    onDecrement: { updateNagDelay(nagDelayMinutes - 1) },
                    onIncrement: { updateNagDelay(nagDelayMinutes + 1) }
                )
                nagStepperRow(
                    title: "Repeat every",
                    value: minutesLabel(minutes: nagIntervalMinutes),
                    identifier: "nag-interval",
                    decrementDisabled: nagIntervalMinutes <= 1,
                    incrementDisabled: nagIntervalMinutes >= 60,
                    onDecrement: { updateNagInterval(nagIntervalMinutes - 1) },
                    onIncrement: { updateNagInterval(nagIntervalMinutes + 1) }
                )
                nagStepperRow(
                    title: "Max reminders",
                    value: "\(nagMaxCount)",
                    identifier: "nag-max-count",
                    decrementDisabled: nagMaxCount <= 1,
                    incrementDisabled: nagMaxCount >= 10,
                    onDecrement: { updateNagMaxCount(nagMaxCount - 1) },
                    onIncrement: { updateNagMaxCount(nagMaxCount + 1) }
                )
            }
        } header: {
            sectionHeader("PERSISTENT REMINDERS")
        } footer: {
            Text("Follow-up reminders are Time Sensitive and can break through Focus modes. They stop as soon as you act on a prompt or file a report.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var digestSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { digestEnabled },
                set: { updateDigestEnabled($0) }
            )) {
                Text("Weekly Digest")
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("digest-enabled")
            .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("WEEKLY DIGEST")
        } footer: {
            Text("A Sunday-evening notification that opens your weekly digest. The digest itself is always available from Settings.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func updateDigestEnabled(_ value: Bool) {
        digestEnabled = value
        prefs.digestEnabled = value
        replan()
    }

    private func nagStepperRow(
        title: String, value: String, identifier: String,
        decrementDisabled: Bool, incrementDisabled: Bool,
        onDecrement: @escaping () -> Void, onIncrement: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.white)
            Spacer()
            Button(action: onDecrement) {
                Image(systemName: "minus.circle")
            }
            .disabled(decrementDisabled)
            .accessibilityIdentifier("\(identifier)-decrement")

            Text(value)
                .frame(minWidth: 48)
                .foregroundStyle(.white)
                .accessibilityIdentifier("\(identifier)-value")

            Button(action: onIncrement) {
                Image(systemName: "plus.circle")
            }
            .disabled(incrementDisabled)
            .accessibilityIdentifier("\(identifier)-increment")
        }
        .foregroundStyle(.white)
        .listRowBackground(Color.white.opacity(0.12))
    }

    private func minutesLabel(minutes: Int) -> String {
        "\(minutes) min"
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

    private func updateNagEnabled(_ value: Bool) {
        nagEnabled = value
        prefs.nagEnabled = value
        replan()
    }

    private func updateNagDelay(_ value: Int) {
        let clamped = max(1, min(120, value))
        nagDelayMinutes = clamped
        prefs.nagDelayMinutes = clamped
        replan()
    }

    private func updateNagInterval(_ value: Int) {
        let clamped = max(1, min(60, value))
        nagIntervalMinutes = clamped
        prefs.nagIntervalMinutes = clamped
        replan()
    }

    private func updateNagMaxCount(_ value: Int) {
        let clamped = max(1, min(10, value))
        nagMaxCount = clamped
        prefs.nagMaxCount = clamped
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
