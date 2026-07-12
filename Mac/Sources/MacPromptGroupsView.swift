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
    // Place/beacon triggers (plan 45) are configured on iPhone via CLMonitor;
    // the Mac can't pick a region or register a beacon, so these are shown
    // read-only and never offered when creating a group (see availableKinds).
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
    /// Place/beacon groups can only be viewed (not created) on the Mac.
    var isTriggerOnly: Bool {
        switch self {
        case .placeTrigger, .beaconTrigger: true
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
    /// A `.calendars([...])` rule references the phone's calendars, which the
    /// Mac can't enumerate — preserved read-only when already set.
    private let pinnedCalendarIDs: [String]?
    /// A place/beacon trigger (plan 45) the Mac can't reconfigure — preserved
    /// verbatim on save so viewing a group here never drops its iPhone trigger.
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
        case .placeTrigger: kind = .placeTrigger; lockedTrigger = group?.schedule
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
                    .disabled(questionIDs.isEmpty)
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
            case .placeTrigger, .beaconTrigger:
                Text("Triggered by a place or beacon set on your iPhone. Configure the trigger on iOS; you can still edit this group's questions and name here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mac-group-trigger-note")
            }
        }
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
        // Preserved verbatim — the Mac can't reconfigure a place/beacon trigger.
        case .placeTrigger, .beaconTrigger: lockedTriggerSchedule ?? .disabled
        }
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
