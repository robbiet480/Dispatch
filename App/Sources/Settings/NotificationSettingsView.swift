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
    @Environment(SleepObserver.self) private var sleepObserver
    @Environment(\.notificationPrefs) private var prefs
    @Environment(\.scenePhase) private var scenePhase

    @State private var randomCheckInsEnabled: Bool
    @State private var alertsPerDay: Int
    @State private var distribution: PromptDistribution
    @State private var scheduledTimes: [DateComponents]
    @State private var nagEnabled: Bool
    @State private var nagDelayMinutes: Int
    @State private var nagIntervalMinutes: Int
    @State private var nagMaxCount: Int
    @State private var digestSchedules: [DigestSchedule]
    @State private var autoSleepEnabled: Bool
    /// What the "NEXT NOTIFICATION" hero shows. `.loading` renders the
    /// same layout as `.empty` with blank strings so the slot doesn't jump
    /// when the async pending-requests read lands.
    private enum NextAlertState: Equatable {
        case loading
        /// A pending prompt exists: big time + source caption.
        case scheduled(time: String, caption: String)
        /// No pending prompt: honest explanation instead of a dash.
        case empty(title: String, caption: String)
    }

    @State private var nextAlertState: NextAlertState = .loading
    @State private var isAddingTime = false
    @State private var newTimeSelection = Date()

    /// Digest add-sheet selection (plan 40). The cadence kind drives which
    /// day picker shows; weekday/dayOfMonth carry the chosen anchor.
    private enum DigestCadenceKind: String, CaseIterable, Identifiable {
        case weekly = "Weekly"
        case monthly = "Monthly"
        case quarterly = "Quarterly"
        var id: String { rawValue }
    }
    @State private var isAddingDigest = false
    @State private var newDigestCadence: DigestCadenceKind = .weekly
    @State private var newDigestWeekday = 1
    @State private var newDigestDayOfMonth = 1
    @State private var newDigestTime = Date()

    private var theme: Theme { themeStore.theme }

    init(prefs: NotificationPrefs) {
        _randomCheckInsEnabled = State(initialValue: prefs.randomCheckInsEnabled)
        _alertsPerDay = State(initialValue: prefs.alertsPerDay)
        _distribution = State(initialValue: prefs.distribution)
        _scheduledTimes = State(initialValue: prefs.scheduledTimes)
        _nagEnabled = State(initialValue: prefs.nagEnabled)
        _nagDelayMinutes = State(initialValue: prefs.nagDelayMinutes)
        _nagIntervalMinutes = State(initialValue: prefs.nagIntervalMinutes)
        _nagMaxCount = State(initialValue: prefs.nagMaxCount)
        _digestSchedules = State(initialValue: prefs.digestSchedules)
        _autoSleepEnabled = State(initialValue: prefs.autoSleepEnabled)
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                nextNotificationSection
                focusFilterSection
                sleepSection
                frequencySection
                // DISTRIBUTION only shapes the RANDOM schedule, so it's hidden
                // when random check-ins are off (plan 51). SCHEDULED (explicit
                // fixed times) stays — it's independent of the random toggle.
                if randomCheckInsEnabled {
                    distributionSection
                }
                scheduledSection
                nagSection
                digestSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Plan 27: readable column on iPad; no-op at iPhone widths.
            .readableColumn()
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear(perform: refreshNextAlert)
        // Returning from background (e.g. after flipping notification
        // permission in iOS Settings, or after the foreground replan ran)
        // can change the pending schedule — re-read it.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { refreshNextAlert() }
        }
        .sheet(isPresented: $isAddingTime) {
            addTimeSheet
        }
        .sheet(isPresented: $isAddingDigest) {
            addDigestSheet
        }
    }

    // MARK: - Sections

    private var nextNotificationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                // The title keeps a 48pt slot (the 40pt time's line height)
                // in every state so the layout doesn't jump between the big
                // time and the smaller empty-state title.
                Group {
                    switch nextAlertState {
                    case .loading:
                        Text(verbatim: "")
                    case .scheduled(let time, _):
                        Text(time)
                            .font(.system(size: 40, weight: .light, design: .rounded))
                    case .empty(let title, _):
                        Text(title)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                    }
                }
                .frame(minHeight: 48)
                .foregroundStyle(.white)
                .accessibilityIdentifier("next-notification-time")

                Text(nextAlertCaption)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityIdentifier("next-notification-source")
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
            .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("NEXT NOTIFICATION")
        }
    }

    private var nextAlertCaption: String {
        switch nextAlertState {
        case .loading: ""
        case .scheduled(_, let caption), .empty(_, let caption): caption
        }
    }

    /// Passive status row (plan 15): visible only while a Dispatch Focus
    /// Filter is active, so the user can tell at a glance why prompts are
    /// quieter than the settings below suggest. Read fresh from the
    /// scheduler on each body evaluation — the row appears/disappears on
    /// navigation, which is enough for a passive indicator.
    @ViewBuilder private var focusFilterSection: some View {
        if let filter = scheduler.activeFocusFilter {
            // nil allowedGroupIDs = name-only filter: no group restriction.
            let groupsText = filter.allowedGroupIDs
                .map { "\($0.count) group\($0.count == 1 ? "" : "s")" } ?? "all groups"
            let scopeText = filter.allowedGroupIDs == nil
                ? "All prompt groups are firing"
                : "Only these prompt groups are firing"
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Focus filter: \(filter.label) — \(groupsText)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                    Text(filter.allowsGlobal
                         ? "\(scopeText); ungrouped prompts continue."
                         : "\(scopeText); ungrouped prompts are paused.")
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

    /// Plan 39: the one switch for the whole auto awake/asleep feature.
    /// Lives here (not Sensors) because the awake state exists to gate the
    /// prompt schedule and its siblings (hero empty-state, focus-filter
    /// status row) already live on this screen; Sensors is about what a
    /// REPORT captures, and this captures nothing.
    private var sleepSection: some View {
        Section {
            Toggle("Set automatically from Sleep Focus & Health", isOn: $autoSleepEnabled)
                .foregroundStyle(.white)
                .tint(.white.opacity(0.4))
                .accessibilityIdentifier("auto-sleep-toggle")
                .onChange(of: autoSleepEnabled) { _, enabled in
                    prefs.autoSleepEnabled = enabled
                    sleepObserver.refresh()   // arm/disarm background delivery now
                    replan()
                }
                .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("SLEEP")
        } footer: {
            Text("Marks you asleep when a Focus with Dispatch's filter set to \"This Focus Means I'm Asleep\" turns on (Settings → Focus → Sleep → Focus Filters → Dispatch), and corrects the state from Health sleep data after the fact. Your manual toggle always wins for 90 minutes.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .listRowBackground(Color.clear)
        }
    }

    private var frequencySection: some View {
        Section {
            // Plan 51: the switch that fully disables the app's own random
            // check-ins, so a user can rely on Prompt Groups only. Default ON
            // (existing behavior). When off, the alerts-per-day stepper below
            // and the DISTRIBUTION section are hidden — they only shape the
            // random schedule this switch just turned off.
            Toggle(isOn: Binding(
                get: { randomCheckInsEnabled },
                set: { updateRandomCheckInsEnabled($0) }
            )) {
                Text("Random Check-ins")
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("random-checkins-toggle")
            .listRowBackground(Color.white.opacity(0.12))

            if randomCheckInsEnabled {
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
                // Two Buttons in one List row: without an explicit style the
                // whole row is a single tap target that fires BOTH actions (see
                // SensorSettingsView's capsule buttons for the same pattern).
                .buttonStyle(.borderless)
                .foregroundStyle(.white)
                .listRowBackground(Color.white.opacity(0.12))
            }
        } header: {
            sectionHeader("FREQUENCY")
        } footer: {
            Text(randomCheckInsEnabled
                 ? "Random prompts a few times a day. Turn off to only get your Prompt Groups."
                 : "Off — only your Prompt Groups (and any Scheduled times below) will notify you.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityIdentifier("random-checkins-caption")
                .listRowBackground(Color.clear)
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
                // Title case like the app's other action rows ("Request All
                // Sensors…", "Delete All Data…") — all-caps read as a
                // section header, not a tappable action.
                Text("Add a Notification Time…")
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
                .listRowBackground(Color.clear)
        }
    }

    private var digestSection: some View {
        Section {
            ForEach(sortedDigestSchedules) { schedule in
                Toggle(isOn: digestEnabledBinding(for: schedule)) {
                    Text(scheduleLabel(schedule))
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("digest-schedule-toggle-\(schedule.id.uuidString)")
                .listRowBackground(Color.white.opacity(0.12))
            }
            .onDelete(perform: deleteDigestSchedules)

            Button {
                newDigestCadence = .weekly
                newDigestWeekday = 1
                newDigestDayOfMonth = 1
                newDigestTime = Date()
                isAddingDigest = true
            } label: {
                Text("Add a Digest…")
                    .foregroundStyle(.white)
            }
            // Budget-honesty cap (plan 40): digests occupy the 64-request
            // system cap too, so hold them to 8 to never crowd out prompts.
            .disabled(digestSchedules.count >= 8)
            .accessibilityIdentifier("digest-add-schedule")
            .listRowBackground(Color.white.opacity(0.12))
        } header: {
            sectionHeader("DIGESTS")
        } footer: {
            Text("Each digest is a notification that opens your digest for the period. Monthly and quarterly digests on short months fire on the month's last day. The weekly digest is always available from Settings.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .listRowBackground(Color.clear)
        }
    }

    private var addDigestSheet: some View {
        NavigationStack {
            ZStack {
                Color.themeBackground(theme)
                    .ignoresSafeArea()

                Form {
                    Picker("Cadence", selection: $newDigestCadence) {
                        ForEach(DigestCadenceKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("digest-cadence-picker")
                    .listRowBackground(Color.white.opacity(0.12))

                    if newDigestCadence == .weekly {
                        Picker("Day", selection: $newDigestWeekday) {
                            ForEach(1...7, id: \.self) { weekday in
                                Text(Self.weekdaySymbols[weekday - 1]).tag(weekday)
                            }
                        }
                        .accessibilityIdentifier("digest-day-picker")
                        .listRowBackground(Color.white.opacity(0.12))
                    } else {
                        Picker("Day of Month", selection: $newDigestDayOfMonth) {
                            ForEach(1...31, id: \.self) { day in
                                Text("Day \(day)").tag(day)
                            }
                        }
                        .accessibilityIdentifier("digest-day-picker")
                        .listRowBackground(Color.white.opacity(0.12))
                    }

                    DatePicker("Time", selection: $newDigestTime,
                               displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .accessibilityIdentifier("digest-time-picker")
                        .listRowBackground(Color.white.opacity(0.12))

                    if newDigestCadence != .weekly {
                        Text("Months shorter than your chosen day fire on their last day.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .listRowBackground(Color.clear)
                    }
                }
                .scrollContentBackground(.hidden)
                .foregroundStyle(.white)
                .colorScheme(.dark)
            }
            .navigationTitle("New Digest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isAddingDigest = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addDigestSchedule()
                        isAddingDigest = false
                    }
                    .accessibilityIdentifier("digest-add-confirm")
                }
            }
        }
        .presentationDetents([.medium])
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
        // Same borderless scoping as the Alerts per Day row — two Buttons
        // in one List row need their own tap targets.
        .buttonStyle(.borderless)
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

    private func updateRandomCheckInsEnabled(_ value: Bool) {
        randomCheckInsEnabled = value
        prefs.randomCheckInsEnabled = value
        replan()
    }

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

    // MARK: - Digest schedules (plan 40)

    private func addDigestSchedule() {
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute], from: newDigestTime)
        let cadence: DigestSchedule.Cadence = switch newDigestCadence {
        case .weekly: .weekly(weekday: newDigestWeekday)
        case .monthly: .monthly(dayOfMonth: newDigestDayOfMonth)
        case .quarterly: .quarterly(dayOfMonth: newDigestDayOfMonth)
        }
        let schedule = DigestSchedule(id: UUID(), cadence: cadence,
                                      hour: time.hour ?? 0, minute: time.minute ?? 0,
                                      isEnabled: true)
        var updated = digestSchedules
        updated.append(schedule)
        commitDigestSchedules(updated)
    }

    private func deleteDigestSchedules(at offsets: IndexSet) {
        // Offsets index into the SORTED rows — map them back to identities
        // before mutating the unsorted store (the deleteScheduledTimes trap).
        let sorted = sortedDigestSchedules
        let idsToRemove = Set(offsets.map { sorted[$0].id })
        commitDigestSchedules(digestSchedules.filter { !idsToRemove.contains($0.id) })
    }

    private func digestEnabledBinding(for schedule: DigestSchedule) -> Binding<Bool> {
        Binding(
            get: { digestSchedules.first { $0.id == schedule.id }?.isEnabled ?? false },
            set: { newValue in
                var updated = digestSchedules
                guard let index = updated.firstIndex(where: { $0.id == schedule.id }) else { return }
                updated[index].isEnabled = newValue
                commitDigestSchedules(updated)
            }
        )
    }

    private func commitDigestSchedules(_ schedules: [DigestSchedule]) {
        digestSchedules = schedules
        prefs.digestSchedules = schedules
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
        scheduler.nextPrompt { next in
            Task { @MainActor in
                if let next {
                    nextAlertState = .scheduled(
                        time: Self.timeFormatter.string(from: next.date),
                        caption: caption(for: next.source))
                } else {
                    nextAlertState = await emptyNextAlertState()
                }
            }
        }
    }

    /// Caption under the hero time: the ACTUAL source of the next pending
    /// prompt (the old UI hardcoded "FROM DISTRIBUTION" regardless).
    @MainActor private func caption(for source: NextPromptSource) -> String {
        switch source {
        case .distribution:
            "FROM DISTRIBUTION"
        case .scheduledTime:
            "SCHEDULED TIME"
        case .promptGroup(let groupID):
            if let name = scheduler.promptGroupName(forID: groupID) {
                "FROM GROUP \(name.uppercased())"
            } else {
                "FROM PROMPT GROUP"
            }
        case .snooze:
            "SNOOZED PROMPT"
        }
    }

    /// Honest empty state when nothing is pending, in order of likelihood:
    /// permission missing → point at iOS Settings; marked asleep → the
    /// replan clears all prompts until wake; otherwise the schedule simply
    /// hasn't been planned/added yet — a full replan runs on every app
    /// foreground (DispatchApp's scenePhase .active handler), so that's the
    /// truthful "when it fixes itself" line.
    @MainActor private func emptyNextAlertState() async -> NextAlertState {
        switch await scheduler.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            if awakeStore.isAwake {
                .empty(title: "No prompts scheduled",
                       caption: "A NEW SCHEDULE IS PLANNED WHEN THE APP OPENS")
            } else {
                // Plan 39 honesty: name the automation source that marked
                // the user asleep; the manual caption stays byte-identical.
                switch awakeStore.lastChangeSource {
                case .focusFilter:
                    .empty(title: "No prompts scheduled",
                           caption: "SLEEP FOCUS MARKED YOU ASLEEP — PROMPTS RESUME AT WAKE")
                case .health:
                    .empty(title: "No prompts scheduled",
                           caption: "HEALTH DATA MARKED YOU ASLEEP — PROMPTS RESUME AT WAKE")
                case .manual, nil:
                    .empty(title: "No prompts scheduled",
                           caption: "YOU'RE MARKED ASLEEP — PROMPTS RESUME AT WAKE")
                }
            }
        default: // .denied, .notDetermined
            .empty(title: "Notifications are off",
                   caption: "ENABLE IN iOS SETTINGS TO GET PROMPTS")
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

    // MARK: - Digest helpers (plan 40)

    private static let weekdaySymbols: [String] = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        return calendar.weekdaySymbols // index 0 = Sunday
    }()

    /// Rows sorted by cadence rank (weekly, monthly, quarterly) → day → time.
    /// Stable, no reorder UI.
    private var sortedDigestSchedules: [DigestSchedule] {
        digestSchedules.sorted { lhs, rhs in
            let lhsRank = cadenceRank(lhs.cadence)
            let rhsRank = cadenceRank(rhs.cadence)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsDay = cadenceDay(lhs.cadence)
            let rhsDay = cadenceDay(rhs.cadence)
            if lhsDay != rhsDay { return lhsDay < rhsDay }
            return (lhs.hour * 60 + lhs.minute) < (rhs.hour * 60 + rhs.minute)
        }
    }

    private func cadenceRank(_ cadence: DigestSchedule.Cadence) -> Int {
        switch cadence {
        case .weekly: return 0
        case .monthly: return 1
        case .quarterly: return 2
        }
    }

    private func cadenceDay(_ cadence: DigestSchedule.Cadence) -> Int {
        switch cadence {
        case let .weekly(weekday): return weekday
        case let .monthly(dayOfMonth), let .quarterly(dayOfMonth): return dayOfMonth
        }
    }

    /// "Weekly · Sunday · 7:00 PM" / "Monthly · Day 31 · 9:00 AM".
    private func scheduleLabel(_ schedule: DigestSchedule) -> String {
        let cadenceWord: String
        let dayWord: String
        switch schedule.cadence {
        case let .weekly(weekday):
            cadenceWord = "Weekly"
            dayWord = Self.weekdaySymbols[max(0, min(6, weekday - 1))]
        case let .monthly(dayOfMonth):
            cadenceWord = "Monthly"
            dayWord = "Day \(dayOfMonth)"
        case let .quarterly(dayOfMonth):
            cadenceWord = "Quarterly"
            dayWord = "Day \(dayOfMonth)"
        }
        var components = DateComponents()
        components.hour = schedule.hour
        components.minute = schedule.minute
        let timeText = Calendar.current.date(from: components)
            .map { Self.localizedTimeFormatter.string(from: $0) }
            ?? String(format: "%02d:%02d", schedule.hour, schedule.minute)
        return "\(cadenceWord) · \(dayWord) · \(timeText)"
    }

    private static let localizedTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

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
