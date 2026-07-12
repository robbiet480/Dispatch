import DispatchKit
import SwiftData
import SwiftUI

/// Settings → Prompt Groups (plan 12): named question groups, each with its
/// own Timed or Event notification schedule. Every mutation triggers a
/// replan so the pending-notification schedule always reflects the models.
struct PromptGroupsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.notificationPrefs) private var notificationPrefs
    @Environment(NotificationScheduler.self) private var scheduler
    @Environment(AwakeStore.self) private var awakeStore
    @Environment(ThemeStore.self) private var themeStore
    @Environment(WorkoutEndObserver.self) private var workoutEndObserver
    @Environment(VisitObserver.self) private var visitObserver
    @Environment(CalendarEventObserver.self) private var calendarEventObserver
    @Query(sort: \PromptGroup.sortOrder) private var groups: [PromptGroup]

    private var theme: Theme { themeStore.theme }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                if groups.isEmpty {
                    Text("Group questions together and give each group its own schedule — "
                        + "every few hours, a few times a day, at set times, when a workout ends, "
                        + "when you arrive somewhere, when a calendar event ends, "
                        + "when you arrive at or leave a place, or when you're near a beacon. "
                        + "Ungrouped questions keep using the main notification schedule.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .listRowBackground(Color.white.opacity(0.12))
                        .accessibilityIdentifier("prompt-groups-empty")
                }

                ForEach(groups, id: \.uniqueIdentifier) { group in
                    PromptGroupRowView(group: group, onChange: replan)
                        .listRowBackground(Color.white.opacity(0.12))
                }
                .onMove(perform: move)
                .onDelete(perform: delete)

                NavigationLink(destination: PromptGroupEditorView(group: nil)) {
                    Text("ADD A GROUP…")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
                .listRowBackground(Color.white.opacity(0.12))
                .accessibilityIdentifier("group-add")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Plan 27: readable column on iPad; no-op at iPhone widths.
            .readableColumn()
            .accessibilityIdentifier("prompt-groups")
        }
        .navigationTitle("Prompt Groups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .tint(.white)
            }
        }
    }

    private func move(fromOffsets: IndexSet, toOffset: Int) {
        var reordered = groups
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (index, group) in reordered.enumerated() {
            group.sortOrder = index
        }
        try? context.save()
        replan()
    }

    private func delete(at offsets: IndexSet) {
        for offset in offsets {
            context.delete(groups[offset])
        }
        try? context.save()
        replan()
    }

    private func replan() {
        scheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
        workoutEndObserver.refresh()
        visitObserver.refresh()
        calendarEventObserver.refresh()
    }
}

struct PromptGroupRowView: View {
    @Environment(VisitObserver.self) private var visitObserver
    @Environment(MonitorObserver.self) private var monitorObserver
    @Environment(CalendarEventObserver.self) private var calendarEventObserver
    let group: PromptGroup
    let onChange: () -> Void

    var body: some View {
        NavigationLink(destination: PromptGroupEditorView(group: group)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName.uppercased())
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text("\(group.schedule.summary) – \(questionCountText)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    // A visit group without Always location simply doesn't
                    // fire (plan 16) — say so where the user will look.
                    if group.schedule == .visitArrival, !visitObserver.hasAlwaysAuthorization {
                        Text("Needs “Always” location — won't fire")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityIdentifier("group-row-needs-always")
                    }
                    // A calendar group without full calendar access likewise
                    // simply doesn't fire (plan 31) — say so in place.
                    if isCalendarGroup, !calendarEventObserver.hasFullAccess {
                        Text("Needs calendar access — won't fire")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityIdentifier("group-row-needs-calendar")
                    }
                    // Place/beacon groups need Always location; without it they
                    // don't fire (plan 45), same as visit groups.
                    if isMonitorGroup, !monitorObserver.hasAlwaysAuthorization {
                        Text("Needs “Always” location — won't fire")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityIdentifier("group-row-needs-always")
                    }
                    // Dropped past the ~20-condition CLMonitor budget.
                    if isMonitorGroup,
                       monitorObserver.droppedGroupIDs.contains(group.uniqueIdentifier) {
                        Text("Not monitored — too many location/beacon groups")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityIdentifier("group-row-over-budget")
                    }
                }

                Spacer()

                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .tint(.white.opacity(0.4))
            }
        }
    }

    private var isCalendarGroup: Bool {
        if case .calendarEventEnd = group.schedule { return true }
        return false
    }

    private var isMonitorGroup: Bool {
        switch group.schedule {
        case .placeTrigger, .beaconTrigger: return true
        default: return false
        }
    }

    private var displayName: String {
        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled group" : name
    }

    private var questionCountText: String {
        let count = group.questionIDs.count
        return count == 1 ? "1 question" : "\(count) questions"
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { group.isEnabled },
            set: {
                group.isEnabled = $0
                try? group.modelContext?.save()
                onChange()
            }
        )
    }
}

// GroupSchedule.summary moved to DispatchKit (QuestionDisplay.swift, plan 47)
// so the iOS and macOS group lists share one definition. Place/beacon summary
// cases (plan 45) live there too.

// MARK: - Editor

/// The schedule-kind rows of the editor picker. `.disabled` (unknown raw) is
/// deliberately not offered; editing such a group defaults the picker to
/// timesPerDay and saving overwrites the unknown kind.
private enum EditableScheduleKind: String, CaseIterable, Identifiable {
    case everyNHours, timesPerDay, dailyAt, workoutEnd, visitArrival, calendarEventEnd
    case placeTrigger, beaconTrigger
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .everyNHours: "Every N hours"
        case .timesPerDay: "Times per day"
        case .dailyAt: "Daily at times"
        case .workoutEnd: "When a workout ends"
        case .visitArrival: "When I arrive somewhere"
        case .calendarEventEnd: "When a calendar event ends"
        case .placeTrigger: "When I arrive at / leave a place"
        case .beaconTrigger: "When I'm near a beacon"
        }
    }
}

/// The editor's draft of a calendar group's match rule kind (plan 31);
/// committed to a `CalendarEventMatchRule` on save.
private enum CalendarMatchKindDraft: String, CaseIterable, Identifiable {
    case allEvents, calendars, titleContains
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allEvents: "All events"
        case .calendars: "Specific calendars"
        case .titleContains: "Title contains"
        }
    }
}

struct PromptGroupEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.notificationPrefs) private var notificationPrefs
    @Environment(NotificationScheduler.self) private var scheduler
    @Environment(AwakeStore.self) private var awakeStore
    @Environment(ThemeStore.self) private var themeStore
    @Environment(WorkoutEndObserver.self) private var workoutEndObserver
    @Environment(VisitObserver.self) private var visitObserver
    @Environment(MonitorObserver.self) private var monitorObserver
    @Environment(CalendarEventObserver.self) private var calendarEventObserver
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    @Query(sort: \PromptGroup.sortOrder) private var groups: [PromptGroup]

    /// nil ⇒ creating a new group.
    let group: PromptGroup?

    /// Local @State drafts throughout — committed on Save, never written to
    /// an observable per keystroke (see LocalTextEditorField's doc comment).
    @State private var name: String
    @State private var questionIDs: [String]
    @State private var scheduleKind: EditableScheduleKind
    @State private var everyHours: Int
    @State private var timesPerDay: Int
    @State private var distribution: PromptDistribution
    @State private var dailyTimes: [String]
    @State private var calendarMatchKind: CalendarMatchKindDraft
    @State private var selectedCalendarIDs: [String]
    @State private var titleFilter: String
    // Place/beacon trigger drafts (plan 45). Shared: direction/delay/cancel.
    @State private var monitorDirection: MonitorDirection
    @State private var monitorDelayMinutes: Int
    @State private var monitorCancelOnContradiction: Bool
    @State private var placeLatitude: String
    @State private var placeLongitude: String
    @State private var placeRadius: Double
    @State private var placeName: String
    @State private var beaconUUID: String
    @State private var beaconMajor: String
    @State private var beaconMinor: String
    @State private var beaconName: String
    @State private var isEnabled: Bool
    @State private var newTime = Date()
    /// Place-search (plan 50, #83): the shared MapKit autocomplete/geocode model
    /// plus the live search text. Picking a result fills the place drafts above
    /// (`placeLatitude`/`placeLongitude`/`placeName`); the advanced manual
    /// disclosure still writes them directly.
    @State private var placeSearch = PlaceSearchModel.makeForCurrentProcess()
    @State private var placeSearchText = ""

    private var theme: Theme { themeStore.theme }

    init(group: PromptGroup?) {
        self.group = group
        _name = State(initialValue: group?.name ?? "")
        _questionIDs = State(initialValue: group?.questionIDs ?? [])
        _isEnabled = State(initialValue: group?.isEnabled ?? true)

        var kind = EditableScheduleKind.timesPerDay
        var hours = 4
        var count = 4
        var dist = PromptDistribution.semiRandom
        var times: [String] = []
        var matchKind = CalendarMatchKindDraft.allEvents
        var calendarIDs: [String] = []
        var title = ""
        var direction = MonitorDirection.arrival
        var delayMinutes = 0
        var cancelOnContradiction = true
        var latitude = ""
        var longitude = ""
        var radius = MonitorDelay.floorRadiusMeters
        var placeNameDraft = ""
        var uuid = ""
        var major = ""
        var minor = ""
        var beaconNameDraft = ""
        switch group?.schedule {
        case .everyNHours(let n):
            kind = .everyNHours; hours = n
        case .timesPerDay(let c, let d):
            kind = .timesPerDay; count = c; dist = d
        case .dailyAt(let components):
            kind = .dailyAt
            times = components.map(PromptGroup.timeString(fromComponents:))
        case .workoutEnd:
            kind = .workoutEnd
        case .visitArrival:
            kind = .visitArrival
        case .calendarEventEnd(let rule):
            kind = .calendarEventEnd
            switch rule {
            case .allEvents:
                matchKind = .allEvents
            case .calendars(let ids):
                matchKind = .calendars; calendarIDs = ids
            case .titleContains(let filter):
                matchKind = .titleContains; title = filter
            }
        case .placeTrigger(let trigger):
            kind = .placeTrigger
            direction = trigger.direction
            delayMinutes = MonitorDelay.nearestAllowedMinutes(trigger.delayMinutes)
            cancelOnContradiction = trigger.cancelOnContradiction
            latitude = String(trigger.region.latitude)
            longitude = String(trigger.region.longitude)
            radius = trigger.region.radius
            placeNameDraft = trigger.region.name ?? ""
        case .beaconTrigger(let trigger):
            kind = .beaconTrigger
            direction = trigger.direction
            delayMinutes = MonitorDelay.nearestAllowedMinutes(trigger.delayMinutes)
            cancelOnContradiction = trigger.cancelOnContradiction
            uuid = trigger.beacon.uuid
            major = trigger.beacon.major.map(String.init) ?? ""
            minor = trigger.beacon.minor.map(String.init) ?? ""
            beaconNameDraft = trigger.beacon.name ?? ""
        case .disabled, nil:
            break
        }
        _scheduleKind = State(initialValue: kind)
        _everyHours = State(initialValue: hours)
        _timesPerDay = State(initialValue: count)
        _distribution = State(initialValue: dist)
        _dailyTimes = State(initialValue: times)
        _calendarMatchKind = State(initialValue: matchKind)
        _selectedCalendarIDs = State(initialValue: calendarIDs)
        _titleFilter = State(initialValue: title)
        _monitorDirection = State(initialValue: direction)
        _monitorDelayMinutes = State(initialValue: delayMinutes)
        _monitorCancelOnContradiction = State(initialValue: cancelOnContradiction)
        _placeLatitude = State(initialValue: latitude)
        _placeLongitude = State(initialValue: longitude)
        _placeRadius = State(initialValue: radius)
        _placeName = State(initialValue: placeNameDraft)
        _beaconUUID = State(initialValue: uuid)
        _beaconMajor = State(initialValue: major)
        _beaconMinor = State(initialValue: minor)
        _beaconName = State(initialValue: beaconNameDraft)
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            Form {
                Section {
                    TextField("Name", text: $name)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .accessibilityIdentifier("group-name")
                } header: {
                    sectionHeader("NAME")
                }
                .listRowBackground(Color.white.opacity(0.12))

                questionsSection
                scheduleSection

                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .accessibilityIdentifier("group-enabled")
                } footer: {
                    Text("Disabled groups keep their questions but never fire notifications.")
                        .foregroundStyle(.white.opacity(0.7))
                        .listRowBackground(Color.clear)
                }
                .listRowBackground(Color.white.opacity(0.12))
            }
            .scrollContentBackground(.hidden)
            // Plan 27: readable column on iPad; no-op at iPhone widths.
            .readableColumn()
        }
        .navigationTitle(group == nil ? "Add Group" : "Edit Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // A group with no questions would fire prompts that open an
                // empty survey — require at least one question to save.
                Button("Save") { save() }
                    .disabled(questionIDs.isEmpty || scheduleValidationMessage != nil)
                    .accessibilityIdentifier("group-save")
            }
        }
    }

    /// Multi-select membership over enabled questions. Selection order IS
    /// the survey order: toggling on appends, toggling off removes.
    private var questionsSection: some View {
        Section {
            ForEach(questions.filter(\.isEnabled), id: \.uniqueIdentifier) { question in
                Button {
                    toggleMembership(of: question.uniqueIdentifier)
                } label: {
                    HStack {
                        Text(question.prompt)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Spacer()
                        if let position = questionIDs.firstIndex(of: question.uniqueIdentifier) {
                            Text("\(position + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.7))
                            Image(systemName: "checkmark")
                                .foregroundStyle(.white)
                        }
                    }
                }
                .accessibilityAddTraits(questionIDs.contains(question.uniqueIdentifier) ? [.isSelected] : [])
            }
            .accessibilityIdentifier("group-questions")
        } header: {
            sectionHeader("QUESTIONS")
        } footer: {
            Text("Tap to add questions in the order they should be asked.")
                .foregroundStyle(.white.opacity(0.7))
                .listRowBackground(Color.clear)
        }
        .listRowBackground(Color.white.opacity(0.12))
    }

    @ViewBuilder
    private var scheduleSection: some View {
        Section {
            Picker("Schedule", selection: $scheduleKind) {
                ForEach(EditableScheduleKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .foregroundStyle(.white)
            .tint(.white.opacity(0.7))
            .accessibilityIdentifier("group-schedule-kind")

            switch scheduleKind {
            case .everyNHours:
                Stepper("Every \(everyHours)h", value: $everyHours, in: 1...12)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("group-every-hours")
            case .timesPerDay:
                Stepper("\(timesPerDay)× per day", value: $timesPerDay, in: 1...12)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("group-times-per-day")
                Picker("Distribution", selection: $distribution) {
                    Text("Random").tag(PromptDistribution.random)
                    Text("Semi-random").tag(PromptDistribution.semiRandom)
                    Text("Regular").tag(PromptDistribution.regular)
                }
                .foregroundStyle(.white)
                .tint(.white.opacity(0.7))
            case .dailyAt:
                ForEach(dailyTimes, id: \.self) { time in
                    HStack {
                        Text(time)
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            dailyTimes.removeAll { $0 == time }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    DatePicker("Add a time", selection: $newTime, displayedComponents: .hourAndMinute)
                        .foregroundStyle(.white)
                        .tint(.white)
                        // The compact picker's value capsule ignores
                        // foregroundStyle — dark scheme keeps it legible
                        // over the themed background (house pattern, see
                        // NotificationSettingsView's wheel picker).
                        .colorScheme(.dark)
                    Button("ADD") { addDailyTime() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("group-add-time")
                }
            case .workoutEnd:
                Text("Fires a prompt shortly after a workout ends.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            case .visitArrival:
                Text("Fires a prompt when you arrive somewhere and settle in — "
                    + "Apple's power-efficient visit detection, so arrivals are "
                    + "noticed after you've been in a place a little while. "
                    + "Needs “Always” location access to work when Dispatch is closed.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                if !visitObserver.hasAlwaysAuthorization {
                    visitAuthorizationHint
                }
            case .calendarEventEnd:
                Text("Fires a prompt when a matching calendar event ends — "
                    + "e.g. “How was the meeting?”. Needs full calendar access "
                    + "to read your events.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                Picker("Match", selection: $calendarMatchKind) {
                    ForEach(CalendarMatchKindDraft.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .foregroundStyle(.white)
                .tint(.white.opacity(0.7))
                .accessibilityIdentifier("group-calendar-match")
                if calendarMatchKind == .calendars {
                    calendarSelectionList
                }
                if calendarMatchKind == .titleContains {
                    TextField("Title contains", text: $titleFilter)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .accessibilityIdentifier("group-calendar-title")
                }
                if !calendarEventObserver.hasFullAccess {
                    calendarAuthorizationHint
                }
            case .placeTrigger:
                Text("Fires a prompt when you arrive at (or leave) a place — "
                    + "e.g. “30 minutes after arriving at the office”. Search for "
                    + "the place by name or address. Needs “Always” location "
                    + "access to work when Dispatch is closed.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                placeSearchField
                placeSelectedRow
                Stepper("Radius \(Int(placeRadius)) m",
                        value: $placeRadius,
                        in: MonitorDelay.floorRadiusMeters...5000, step: 50)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("group-place-radius")
                placeManualEntry
                monitorControls
                monitorValidationHint
                if !monitorObserver.hasAlwaysAuthorization {
                    monitorAuthorizationHint
                }
            case .beaconTrigger:
                Text("Fires a prompt when you come into (or leave) range of an "
                    + "iBeacon — finer-grained than a geofence, e.g. a beacon on "
                    + "your desk or in your car. Cheap ESP32 or tile-style beacons "
                    + "work. Needs “Always” location access.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                TextField("Beacon UUID", text: $beaconUUID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .foregroundStyle(.white).tint(.white)
                    .accessibilityIdentifier("group-beacon-uuid")
                TextField("Major (optional)", text: $beaconMajor)
                    .keyboardType(.numberPad)
                    .foregroundStyle(.white).tint(.white)
                    .accessibilityIdentifier("group-beacon-major")
                TextField("Minor (optional)", text: $beaconMinor)
                    .keyboardType(.numberPad)
                    .foregroundStyle(.white).tint(.white)
                    .accessibilityIdentifier("group-beacon-minor")
                TextField("Beacon name (optional)", text: $beaconName)
                    .foregroundStyle(.white).tint(.white)
                    .accessibilityIdentifier("group-beacon-name")
                monitorControls
                monitorValidationHint
                if !monitorObserver.hasAlwaysAuthorization {
                    monitorAuthorizationHint
                }
            }
        } header: {
            sectionHeader("SCHEDULE")
        }
        .listRowBackground(Color.white.opacity(0.12))
        // Editor-contextual permission asks (plans 16 + 31): the ONLY places
        // the app ever asks — picking the visit/calendar schedule is the
        // moment the section text above has just explained why. Never part
        // of onboarding.
        .onChange(of: scheduleKind) { _, newKind in
            if newKind == .visitArrival, !visitObserver.hasAlwaysAuthorization {
                Task { await visitObserver.requestAlwaysAuthorization() }
            }
            if newKind == .calendarEventEnd, !calendarEventObserver.hasFullAccess {
                Task { await calendarEventObserver.requestFullAccess() }
            }
            if (newKind == .placeTrigger || newKind == .beaconTrigger),
               !monitorObserver.hasAlwaysAuthorization {
                Task { await monitorObserver.requestAlwaysAuthorization() }
            }
        }
    }

    /// Validation for the place/beacon coordinate & identity fields — gates
    /// Save (and drives the inline hint) so a group can never be saved with a
    /// (0,0) coordinate or an unparseable beacon that would silently monitor
    /// the wrong thing / never fire. nil ⇒ valid (or a non-monitor schedule).
    private var scheduleValidationMessage: String? {
        switch scheduleKind {
        case .placeTrigger:
            guard let lat = Double(placeLatitude), (-90.0...90.0).contains(lat),
                  let lon = Double(placeLongitude), (-180.0...180.0).contains(lon)
            else { return "Search for a place and choose a result (or enter coordinates manually)." }
            return nil
        case .beaconTrigger:
            guard UUID(uuidString: beaconUUID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            else { return "Enter a valid beacon UUID (e.g. E2C56DB5-DFFB-48D2-B060-D0F5A71096E0)." }
            for value in [beaconMajor, beaconMinor] where !value.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let number = Int(value), (0...65_535).contains(number)
                else { return "Major and minor must be whole numbers from 0 to 65535." }
            }
            return nil
        default:
            return nil
        }
    }

    /// Inline validation message for the current monitor schedule.
    @ViewBuilder
    private var monitorValidationHint: some View {
        if let message = scheduleValidationMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.yellow)
                .accessibilityIdentifier("group-monitor-invalid")
        }
    }

    /// The place-search field + live autocomplete results (plan 50). Typing
    /// drives the shared `PlaceSearchModel`; tapping a result geocodes it and
    /// fills the place drafts (see `pickPlace`).
    @ViewBuilder
    private var placeSearchField: some View {
        TextField("Search for a place or address", text: $placeSearchText)
            .foregroundStyle(.white).tint(.white)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
            .accessibilityIdentifier("group-place-search")
            .onChange(of: placeSearchText) { _, text in
                placeSearch.updateQuery(text)
            }
        if placeSearch.isResolving {
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Finding place…")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
        }
        if let error = placeSearch.errorMessage {
            Text(error)
                .font(.footnote).foregroundStyle(.yellow)
                .accessibilityIdentifier("group-place-search-error")
        }
        Button {
            Task {
                if let resolved = await placeSearch.useCurrentLocation() {
                    applyResolved(resolved)
                }
            }
        } label: {
            Label("Use current location", systemImage: "location.fill")
                .foregroundStyle(.white)
        }
        .disabled(placeSearch.isResolving)
        .accessibilityIdentifier("group-place-current")
        ForEach(placeSearch.suggestions) { suggestion in
            Button {
                pickPlace(suggestion)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .foregroundStyle(.white)
                    if !suggestion.subtitle.isEmpty {
                        Text(suggestion.subtitle)
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .accessibilityIdentifier("group-place-result")
        }
    }

    /// Confirmation of the currently-chosen coordinate (from search OR manual
    /// entry) — shown whenever the drafts hold a parseable lat/lon.
    @ViewBuilder
    private var placeSelectedRow: some View {
        if let lat = Double(placeLatitude), let lon = Double(placeLongitude) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Selected place" : placeName)
                        .foregroundStyle(.white)
                    Text(String(format: "%.5f, %.5f", lat, lon))
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("group-place-selected")
        }
    }

    /// Advanced fallback: raw latitude/longitude + name entry, collapsed by
    /// default. Preserves the exact-coordinate path (and the frozen ids) for
    /// power users; the search field above is the primary flow.
    @ViewBuilder
    private var placeManualEntry: some View {
        DisclosureGroup {
            TextField("Latitude", text: $placeLatitude)
                .keyboardType(.numbersAndPunctuation)
                .foregroundStyle(.white).tint(.white)
                .accessibilityIdentifier("group-place-latitude")
            TextField("Longitude", text: $placeLongitude)
                .keyboardType(.numbersAndPunctuation)
                .foregroundStyle(.white).tint(.white)
                .accessibilityIdentifier("group-place-longitude")
            TextField("Place name (optional)", text: $placeName)
                .foregroundStyle(.white).tint(.white)
                .accessibilityIdentifier("group-place-name")
        } label: {
            Text("Enter coordinates manually")
                .foregroundStyle(.white)
        }
        .tint(.white)
        .accessibilityIdentifier("group-place-manual")
    }

    /// Geocodes a picked suggestion and fills the place drafts, then clears the
    /// search text so the results list collapses.
    private func pickPlace(_ suggestion: PlaceSuggestion) {
        Task {
            guard let resolved = await placeSearch.select(suggestion) else { return }
            applyResolved(resolved)
        }
    }

    /// Writes a resolved place (from search OR "use current location") into the
    /// place drafts and clears the search text.
    private func applyResolved(_ resolved: ResolvedPlace) {
        placeLatitude = String(resolved.latitude)
        placeLongitude = String(resolved.longitude)
        placeName = resolved.name
        placeSearchText = ""
    }

    /// The shared direction / delay / cancel controls for place and beacon
    /// triggers (plan 45) — identical semantics, so one control set.
    @ViewBuilder
    private var monitorControls: some View {
        Picker("Direction", selection: $monitorDirection) {
            Text("On arrival").tag(MonitorDirection.arrival)
            Text("On departure").tag(MonitorDirection.departure)
        }
        .foregroundStyle(.white)
        .tint(.white.opacity(0.7))
        .accessibilityIdentifier("group-monitor-direction")

        Picker("Delay", selection: $monitorDelayMinutes) {
            ForEach(MonitorDelay.allowedMinutes, id: \.self) { minutes in
                Text(minutes == 0 ? "Immediately" : "\(minutes) min").tag(minutes)
            }
        }
        .foregroundStyle(.white)
        .tint(.white.opacity(0.7))
        .accessibilityIdentifier("group-monitor-delay")

        Toggle("Cancel if I leave before the delay", isOn: $monitorCancelOnContradiction)
            .foregroundStyle(.white)
            .tint(.white)
            .accessibilityIdentifier("group-monitor-cancel")
    }

    /// Inline "needs Always" state while a place/beacon schedule is selected —
    /// the visit twin (denied/restricted points at Settings, else re-offers
    /// the prompt).
    @ViewBuilder
    private var monitorAuthorizationHint: some View {
        switch monitorObserver.authorizationStatus {
        case .denied, .restricted:
            Text("Location access is off — allow “Always” in Settings → Privacy "
                + "& Security → Location Services → Dispatch, or this group won't fire.")
                .font(.footnote)
                .foregroundStyle(.yellow)
                .accessibilityIdentifier("group-monitor-needs-always")
        default:
            Button {
                Task { await monitorObserver.requestAlwaysAuthorization() }
            } label: {
                Text("Needs “Always” location — tap to allow")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.yellow)
            }
            .accessibilityIdentifier("group-monitor-needs-always")
        }
    }

    /// Multi-select over the user's event calendars for the
    /// `.calendars` match rule (the questionsSection checkmark pattern).
    /// Empty WITH full access (no calendars at all) gets its own footnote;
    /// without access the list is empty and the authorization hint below
    /// explains why.
    @ViewBuilder
    private var calendarSelectionList: some View {
        let calendars = calendarEventObserver.eventCalendars()
        if calendars.isEmpty {
            if calendarEventObserver.hasFullAccess {
                Text("No calendars found.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
        } else {
            ForEach(calendars, id: \.id) { calendar in
                Button {
                    toggleCalendarSelection(of: calendar.id)
                } label: {
                    HStack {
                        Text(calendar.title)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Spacer()
                        if selectedCalendarIDs.contains(calendar.id) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.white)
                        }
                    }
                }
                .accessibilityAddTraits(
                    selectedCalendarIDs.contains(calendar.id) ? [.isSelected] : [])
            }
            .accessibilityIdentifier("group-calendar-list")
        }
    }

    /// Inline "needs calendar access" state while the calendar schedule is
    /// selected: denied/restricted/write-only points at Settings (write-only
    /// CANNOT read events — EventKit returns none); anything else re-offers
    /// the system prompt.
    @ViewBuilder
    private var calendarAuthorizationHint: some View {
        switch calendarEventObserver.authorizationStatus {
        case .denied, .restricted, .writeOnly:
            Text("Calendar access is off — allow full access in Settings → "
                + "Privacy & Security → Calendars → Dispatch, or this group "
                + "won't fire. Add-only access can't read events.")
                .font(.footnote)
                .foregroundStyle(.yellow)
                .accessibilityIdentifier("group-calendar-needs-access")
        default:
            Button {
                Task { await calendarEventObserver.requestFullAccess() }
            } label: {
                Text("Needs full calendar access — tap to allow")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.yellow)
            }
            .accessibilityIdentifier("group-calendar-needs-access")
        }
    }

    /// Inline "needs Always" state while the visit schedule is selected:
    /// denied/restricted points at Settings; anything else re-offers the
    /// system prompt.
    @ViewBuilder
    private var visitAuthorizationHint: some View {
        switch visitObserver.authorizationStatus {
        case .denied, .restricted:
            Text("Location access is off — allow “Always” in Settings → Privacy "
                + "& Security → Location Services → Dispatch, or this group won't fire.")
                .font(.footnote)
                .foregroundStyle(.yellow)
                .accessibilityIdentifier("group-visit-needs-always")
        default:
            Button {
                Task { await visitObserver.requestAlwaysAuthorization() }
            } label: {
                Text("Needs “Always” location — tap to allow")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.yellow)
            }
            .accessibilityIdentifier("group-visit-needs-always")
        }
    }

    private func toggleCalendarSelection(of calendarID: String) {
        if let index = selectedCalendarIDs.firstIndex(of: calendarID) {
            selectedCalendarIDs.remove(at: index)
        } else {
            selectedCalendarIDs.append(calendarID)
        }
    }

    private func toggleMembership(of questionID: String) {
        if let index = questionIDs.firstIndex(of: questionID) {
            questionIDs.remove(at: index)
        } else {
            questionIDs.append(questionID)
        }
    }

    private func addDailyTime() {
        var components = Calendar.current.dateComponents([.hour, .minute], from: newTime)
        components.second = nil
        let string = PromptGroup.timeString(fromComponents: components)
        if !dailyTimes.contains(string) {
            dailyTimes.append(string)
            dailyTimes.sort()
        }
    }

    private var draftSchedule: GroupSchedule {
        switch scheduleKind {
        case .everyNHours:
            .everyNHours(everyHours)
        case .timesPerDay:
            .timesPerDay(count: timesPerDay, distribution: distribution)
        case .dailyAt:
            .dailyAt(dailyTimes.compactMap(PromptGroup.timeComponents(fromString:)))
        case .workoutEnd:
            .workoutEnd
        case .visitArrival:
            .visitArrival
        case .calendarEventEnd:
            .calendarEventEnd(draftCalendarRule)
        case .placeTrigger:
            .placeTrigger(PlaceTrigger(
                region: MonitorPlaceRegion(
                    latitude: Double(placeLatitude) ?? 0,
                    longitude: Double(placeLongitude) ?? 0,
                    radius: placeRadius,
                    name: placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil : placeName.trimmingCharacters(in: .whitespacesAndNewlines)),
                direction: monitorDirection,
                delayMinutes: monitorDelayMinutes,
                cancelOnContradiction: monitorCancelOnContradiction))
        case .beaconTrigger:
            .beaconTrigger(BeaconTrigger(
                beacon: MonitorBeaconIdentity(
                    uuid: beaconUUID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                    major: Int(beaconMajor),
                    minor: Int(beaconMinor),
                    name: beaconName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil : beaconName.trimmingCharacters(in: .whitespacesAndNewlines)),
                direction: monitorDirection,
                delayMinutes: monitorDelayMinutes,
                cancelOnContradiction: monitorCancelOnContradiction))
        }
    }

    /// Commits the calendar drafts to a rule. An empty (trimmed) title
    /// filter normalizes to `.allEvents` on save (plan-31 design decision:
    /// degenerate configs are prevented here; `.calendars([])` remains
    /// storable and matches nothing — fails safe).
    private var draftCalendarRule: CalendarEventMatchRule {
        switch calendarMatchKind {
        case .allEvents:
            return .allEvents
        case .calendars:
            return .calendars(selectedCalendarIDs)
        case .titleContains:
            let trimmed = titleFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .allEvents : .titleContains(trimmed)
        }
    }

    private func save() {
        let target = group ?? {
            let newGroup = PromptGroup()
            newGroup.sortOrder = (groups.map(\.sortOrder).max() ?? -1) + 1
            context.insert(newGroup)
            return newGroup
        }()
        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        target.questionIDs = questionIDs
        target.schedule = draftSchedule
        target.isEnabled = isEnabled
        try? context.save()
        scheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
        workoutEndObserver.refresh()
        visitObserver.refresh()
        monitorObserver.refresh()
        calendarEventObserver.refresh()
        dismiss()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }
}
