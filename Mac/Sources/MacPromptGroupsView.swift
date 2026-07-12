import DispatchKit
import SwiftData
import SwiftUI

/// Plan 47 (issue #57): Mac prompt-group management — create/edit/enable/
/// disable/delete groups, membership + ordering, and schedule kinds.
///
/// The Mac has no notification scheduler or sensor providers: editing a group
/// here just WRITES the same `PromptGroup` fields the phone reads. When the
/// edit syncs, the iPhone's `RemoteChangeObserver` replans (plan 47 Task 2 /
/// `RemoteChangeImpact`). Sensor schedule kinds are configurable but labeled
/// "fires on your iPhone" — they execute on iOS/watch only.
struct MacPromptGroupsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PromptGroup.sortOrder) private var groups: [PromptGroup]

    @State private var editingGroup: PromptGroup?
    @State private var isCreating = false
    @State private var pendingDelete: PromptGroup?

    var body: some View {
        List {
            if groups.isEmpty {
                Text("No groups yet. Group questions together and give each group its own schedule. Ungrouped questions keep using the main notification schedule (on your iPhone).")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.uniqueIdentifier) { group in
                MacGroupRow(group: group) { editingGroup = group }
                    .contextMenu {
                        Button("Edit…") { editingGroup = group }
                        Button("Delete", role: .destructive) { pendingDelete = group }
                    }
            }
            .onMove(perform: move)
            .onDelete(perform: delete)
        }
        .accessibilityIdentifier("mac-groups-list")
        .navigationTitle("Prompt Groups")
        .toolbar {
            ToolbarItem {
                Button { isCreating = true } label: {
                    Label("Add Group", systemImage: "plus")
                }
                .accessibilityIdentifier("mac-add-group")
            }
        }
        .sheet(isPresented: $isCreating) {
            MacPromptGroupEditorView(group: nil)
        }
        .sheet(item: $editingGroup) { group in
            MacPromptGroupEditorView(group: group)
        }
        .confirmationDialog(
            "Delete this group?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { group in
            Button("Delete", role: .destructive) {
                context.delete(group)
                try? context.save()
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { group in
            Text("“\(group.name.isEmpty ? "Untitled group" : group.name)” will be removed. Its questions are kept.")
        }
    }

    private func move(fromOffsets: IndexSet, toOffset: Int) {
        var reordered = groups
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (index, group) in reordered.enumerated() { group.sortOrder = index }
        try? context.save()
    }

    private func delete(at offsets: IndexSet) {
        for offset in offsets { context.delete(groups[offset]) }
        try? context.save()
    }
}

private struct MacGroupRow: View {
    @Bindable var group: PromptGroup
    let onEdit: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name.isEmpty ? "Untitled group" : group.name)
                    .font(.body).lineLimit(1)
                Text("\(group.schedule.summary) · \(group.questionIDs.count) question\(group.questionIDs.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") { onEdit() }.buttonStyle(.borderless)
            Toggle("Enabled", isOn: Binding(
                get: { group.isEnabled },
                set: { group.isEnabled = $0; try? group.modelContext?.save() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityIdentifier("mac-group-enabled-\(group.uniqueIdentifier)")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEdit() }
    }
}

// MARK: - Editor

private enum MacScheduleKind: String, CaseIterable, Identifiable {
    case everyNHours, timesPerDay, dailyAt, workoutEnd, visitArrival, calendarEventEnd
    // Place triggers (plan 45) are configured with the shared MapKit place
    // search (plan 50, #83) — the Mac CAN now pick a place, so place is fully
    // creatable here (monitoring still runs on iPhone via CLMonitor). Beacons
    // stay view-only: the Mac can't scan for a beacon (issue #84).
    case placeTrigger, beaconTrigger
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .everyNHours: "Every N hours"
        case .timesPerDay: "Times per day"
        case .dailyAt: "Daily at times"
        case .workoutEnd: "When a workout ends (iPhone)"
        case .visitArrival: "When I arrive somewhere (iPhone)"
        case .calendarEventEnd: "When a calendar event ends (iPhone)"
        case .placeTrigger: "When I arrive at / leave a place (iPhone)"
        case .beaconTrigger: "When I'm near a beacon (iPhone)"
        }
    }
    /// Sensor kinds execute on iOS/watch only.
    var isDeviceOnly: Bool {
        switch self {
        case .everyNHours, .timesPerDay, .dailyAt: false
        case .workoutEnd, .visitArrival, .calendarEventEnd, .placeTrigger, .beaconTrigger: true
        }
    }
    /// Beacon groups can only be viewed (not created) on the Mac — no beacon
    /// scanner (issue #84). Places are creatable (plan 50).
    var isTriggerOnly: Bool {
        switch self {
        case .beaconTrigger: true
        default: false
        }
    }
}

private enum MacCalendarMatch: String, CaseIterable, Identifiable {
    case allEvents, titleContains
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .allEvents: "All events"
        case .titleContains: "Title contains"
        }
    }
}

struct MacPromptGroupEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    @Query(sort: \PromptGroup.sortOrder) private var groups: [PromptGroup]

    let group: PromptGroup?

    @State private var name: String
    @State private var questionIDs: [String]
    @State private var scheduleKind: MacScheduleKind
    @State private var everyHours: Int
    @State private var timesPerDay: Int
    @State private var distribution: PromptDistribution
    @State private var dailyTimes: [String]
    @State private var calendarMatch: MacCalendarMatch
    @State private var titleFilter: String
    @State private var isEnabled: Bool
    @State private var newTime = Date()
    // Place-trigger drafts (plan 50, #83): the Mac now builds a real
    // PlaceTrigger from a searched coordinate + the shared direction/delay/cancel
    // knobs. Beacons remain view-only (preserved via lockedTriggerSchedule).
    @State private var monitorDirection: MonitorDirection
    @State private var monitorDelayMinutes: Int
    @State private var monitorCancelOnContradiction: Bool
    @State private var placeLatitude: String
    @State private var placeLongitude: String
    @State private var placeRadius: Double
    @State private var placeName: String
    @State private var placeSearch = PlaceSearchModel.makeForCurrentProcess()
    @State private var placeSearchText = ""
    /// A `.calendars([...])` rule references the phone's calendars, which the
    /// Mac can't enumerate — preserved read-only when already set.
    private let pinnedCalendarIDs: [String]?
    /// A BEACON trigger (plan 45) the Mac can't reconfigure — preserved verbatim
    /// on save so viewing a beacon group here never drops its iPhone trigger.
    /// Places are no longer locked (plan 50): the Mac builds them for real.
    private let lockedTriggerSchedule: GroupSchedule?

    init(group: PromptGroup?) {
        self.group = group
        _name = State(initialValue: group?.name ?? "")
        _questionIDs = State(initialValue: group?.questionIDs ?? [])
        _isEnabled = State(initialValue: group?.isEnabled ?? true)

        var kind = MacScheduleKind.timesPerDay
        var hours = 4, count = 4
        var dist = PromptDistribution.semiRandom
        var times: [String] = []
        var match = MacCalendarMatch.allEvents
        var title = ""
        var pinned: [String]? = nil
        var lockedTrigger: GroupSchedule? = nil
        var direction = MonitorDirection.arrival
        var delayMinutes = 0
        var cancelOnContradiction = true
        var latitude = ""
        var longitude = ""
        var radius = MonitorDelay.floorRadiusMeters
        var placeNameDraft = ""
        switch group?.schedule {
        case .everyNHours(let n): kind = .everyNHours; hours = n
        case .timesPerDay(let c, let d): kind = .timesPerDay; count = c; dist = d
        case .dailyAt(let comps):
            kind = .dailyAt; times = comps.map(PromptGroup.timeString(fromComponents:))
        case .workoutEnd: kind = .workoutEnd
        case .visitArrival: kind = .visitArrival
        case .calendarEventEnd(let rule):
            kind = .calendarEventEnd
            switch rule {
            case .allEvents: match = .allEvents
            case .titleContains(let filter): match = .titleContains; title = filter
            case .calendars(let ids): pinned = ids
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
        case .beaconTrigger: kind = .beaconTrigger; lockedTrigger = group?.schedule
        case .disabled, nil: break
        }
        lockedTriggerSchedule = lockedTrigger
        _scheduleKind = State(initialValue: kind)
        _everyHours = State(initialValue: hours)
        _timesPerDay = State(initialValue: count)
        _distribution = State(initialValue: dist)
        _dailyTimes = State(initialValue: times)
        _calendarMatch = State(initialValue: match)
        _titleFilter = State(initialValue: title)
        _monitorDirection = State(initialValue: direction)
        _monitorDelayMinutes = State(initialValue: delayMinutes)
        _monitorCancelOnContradiction = State(initialValue: cancelOnContradiction)
        _placeLatitude = State(initialValue: latitude)
        _placeLongitude = State(initialValue: longitude)
        _placeRadius = State(initialValue: radius)
        _placeName = State(initialValue: placeNameDraft)
        pinnedCalendarIDs = pinned
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("mac-group-name")
                }

                Section("Questions") {
                    if questions.filter(\.isEnabled).isEmpty {
                        Text("No enabled questions to add.").foregroundStyle(.secondary)
                    }
                    ForEach(questions.filter(\.isEnabled), id: \.uniqueIdentifier) { question in
                        Button {
                            toggleMembership(of: question.uniqueIdentifier)
                        } label: {
                            HStack {
                                Text(question.prompt).lineLimit(1)
                                Spacer()
                                if let position = questionIDs.firstIndex(of: question.uniqueIdentifier) {
                                    Text("\(position + 1)").foregroundStyle(.secondary)
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                scheduleSection

                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                        .accessibilityIdentifier("mac-group-enabled-toggle")
                } footer: {
                    Text("Disabled groups keep their questions but never fire notifications.")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(questionIDs.isEmpty || !isScheduleValid)
                    .accessibilityIdentifier("mac-group-save")
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 560)
    }

    @ViewBuilder
    private var scheduleSection: some View {
        Section("Schedule") {
            Picker("Schedule", selection: $scheduleKind) {
                ForEach(availableKinds) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .accessibilityIdentifier("mac-group-schedule-kind")

            if scheduleKind.isDeviceOnly {
                Text("Fires on your iPhone — this schedule uses device sensors and runs on iOS/watch only. You can configure it here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mac-group-ios-only-note")
            }

            switch scheduleKind {
            case .everyNHours:
                Stepper("Every \(everyHours)h", value: $everyHours, in: 1...12)
            case .timesPerDay:
                Stepper("\(timesPerDay)× per day", value: $timesPerDay, in: 1...12)
                Picker("Distribution", selection: $distribution) {
                    Text("Random").tag(PromptDistribution.random)
                    Text("Semi-random").tag(PromptDistribution.semiRandom)
                    Text("Regular").tag(PromptDistribution.regular)
                }
            case .dailyAt:
                ForEach(dailyTimes, id: \.self) { time in
                    HStack {
                        Text(time)
                        Spacer()
                        Button {
                            dailyTimes.removeAll { $0 == time }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    DatePicker("Add a time", selection: $newTime, displayedComponents: .hourAndMinute)
                    Button("Add") { addDailyTime() }
                }
            case .workoutEnd:
                Text("Fires a prompt shortly after a workout ends.")
                    .font(.caption).foregroundStyle(.secondary)
            case .visitArrival:
                Text("Fires a prompt when you arrive somewhere and settle in.")
                    .font(.caption).foregroundStyle(.secondary)
            case .calendarEventEnd:
                Text("Fires a prompt when a matching calendar event ends.")
                    .font(.caption).foregroundStyle(.secondary)
                if let pinnedCalendarIDs {
                    Text("Matching \(pinnedCalendarIDs.count) specific calendar\(pinnedCalendarIDs.count == 1 ? "" : "s") chosen on your iPhone. Change the match type to override.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Match", selection: $calendarMatch) {
                    ForEach(MacCalendarMatch.allCases) { match in
                        Text(match.displayName).tag(match)
                    }
                }
                .accessibilityIdentifier("mac-group-calendar-match")
                if calendarMatch == .titleContains {
                    TextField("Title contains", text: $titleFilter)
                        .accessibilityIdentifier("mac-group-calendar-title")
                }
                Text("Calendar matching by specific calendars must be set on your iPhone (the Mac can't read your calendars).")
                    .font(.caption).foregroundStyle(.secondary)
            case .placeTrigger:
                Text("Fires a prompt when you arrive at (or leave) a place. Search for it by name or address — monitoring runs on your iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
                placeSearchField
                placeSelectedRow
                Stepper("Radius \(Int(placeRadius)) m",
                        value: $placeRadius,
                        in: MonitorDelay.floorRadiusMeters...5000, step: 50)
                    .accessibilityIdentifier("mac-group-place-radius")
                macMonitorControls
            case .beaconTrigger:
                Text("Triggered by a beacon set on your iPhone. Configure the beacon on iOS; you can still edit this group's questions and name here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mac-group-trigger-note")
            }
        }
    }

    /// Place-search field + live autocomplete results (plan 50) — the Mac twin
    /// of the iOS editor, standard Form styling. Picking a result geocodes it
    /// and fills the place drafts (see `pickPlace`).
    @ViewBuilder
    private var placeSearchField: some View {
        TextField("Search for a place or address", text: $placeSearchText)
            .accessibilityIdentifier("mac-group-place-search")
            .onChange(of: placeSearchText) { _, text in
                placeSearch.updateQuery(text)
            }
        if placeSearch.isResolving {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finding place…").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let error = placeSearch.errorMessage {
            Text(error)
                .font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("mac-group-place-search-error")
        }
        Button {
            Task {
                if let resolved = await placeSearch.useCurrentLocation() {
                    applyResolved(resolved)
                }
            }
        } label: {
            Label("Use current location", systemImage: "location.fill")
        }
        .disabled(placeSearch.isResolving)
        .accessibilityIdentifier("mac-group-place-current")
        ForEach(placeSearch.suggestions) { suggestion in
            Button {
                pickPlace(suggestion)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                    if !suggestion.subtitle.isEmpty {
                        Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mac-group-place-result")
        }
    }

    /// Confirmation of the currently-chosen coordinate (from search) — shown
    /// whenever the drafts hold a parseable lat/lon.
    @ViewBuilder
    private var placeSelectedRow: some View {
        if let lat = Double(placeLatitude), let lon = Double(placeLongitude) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.circle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Selected place" : placeName)
                    Text(String(format: "%.5f, %.5f", lat, lon))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("mac-group-place-selected")
        }
    }

    /// Shared direction / delay / cancel controls (plan 45) — the Mac twin of
    /// the iOS `monitorControls`.
    @ViewBuilder
    private var macMonitorControls: some View {
        Picker("Direction", selection: $monitorDirection) {
            Text("On arrival").tag(MonitorDirection.arrival)
            Text("On departure").tag(MonitorDirection.departure)
        }
        .accessibilityIdentifier("mac-group-monitor-direction")
        Picker("Delay", selection: $monitorDelayMinutes) {
            ForEach(MonitorDelay.allowedMinutes, id: \.self) { minutes in
                Text(minutes == 0 ? "Immediately" : "\(minutes) min").tag(minutes)
            }
        }
        .accessibilityIdentifier("mac-group-monitor-delay")
        Toggle("Cancel if I leave before the delay", isOn: $monitorCancelOnContradiction)
            .accessibilityIdentifier("mac-group-monitor-cancel")
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

    private func toggleMembership(of id: String) {
        if let index = questionIDs.firstIndex(of: id) {
            questionIDs.remove(at: index)
        } else {
            questionIDs.append(id)
        }
    }

    private func addDailyTime() {
        var comps = Calendar.current.dateComponents([.hour, .minute], from: newTime)
        comps.second = nil
        let string = PromptGroup.timeString(fromComponents: comps)
        if !dailyTimes.contains(string) {
            dailyTimes.append(string)
            dailyTimes.sort()
        }
    }

    /// Trigger kinds only appear when the group already has that schedule; they
    /// can't be created on the Mac (no region/beacon picker), so a fresh group
    /// is never offered one.
    private var availableKinds: [MacScheduleKind] {
        MacScheduleKind.allCases.filter { !$0.isTriggerOnly || $0 == scheduleKind }
    }

    private var draftSchedule: GroupSchedule {
        switch scheduleKind {
        case .everyNHours: .everyNHours(everyHours)
        case .timesPerDay: .timesPerDay(count: timesPerDay, distribution: distribution)
        case .dailyAt: .dailyAt(dailyTimes.compactMap(PromptGroup.timeComponents(fromString:)))
        case .workoutEnd: .workoutEnd
        case .visitArrival: .visitArrival
        case .calendarEventEnd: .calendarEventEnd(draftCalendarRule)
        // Built for real from the searched coordinate (plan 50) — Save is gated
        // on a valid lat/lon (isScheduleValid), so the (0,0) fallback is unreachable.
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
        // Beacons stay view-only on the Mac (issue #84) — preserved verbatim.
        case .beaconTrigger: lockedTriggerSchedule ?? .disabled
        }
    }

    /// Save gate for the place editor: a valid coordinate must be chosen (the
    /// search fills it). Non-place kinds are always coordinate-valid.
    private var isScheduleValid: Bool {
        guard scheduleKind == .placeTrigger else { return true }
        guard let lat = Double(placeLatitude), (-90.0...90.0).contains(lat),
              let lon = Double(placeLongitude), (-180.0...180.0).contains(lon) else { return false }
        return true
    }

    private var draftCalendarRule: CalendarEventMatchRule {
        // Preserve a phone-set specific-calendars rule unless the user picked
        // a different match type here.
        if let pinnedCalendarIDs, calendarMatch == .allEvents, titleFilter.isEmpty {
            return .calendars(pinnedCalendarIDs)
        }
        switch calendarMatch {
        case .allEvents:
            return .allEvents
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
        dismiss()
    }
}
