import DispatchKit
import SwiftData
import SwiftUI

/// The reusable, themed list of prompt groups. Selection-based (like
/// `QuestionsList` / `CatalogListView`) so the same view is BOTH a push-list —
/// iPhone/Settings, wrapped by `PromptGroupsView` in an ambient
/// `NavigationStack` with a `.navigationDestination(item:)` that pushes the
/// editor — AND, once the Sprint-3 shell lands, a split-view sidebar whose
/// selection drives a `PromptGroupEditorView` in the adjacent detail column.
///
/// Rows are tagged by `group.uniqueIdentifier` and participate in
/// `List(selection:)`; the enclosing host owns what a selection means (push vs
/// detail column). Carries the Task 2.4 Mac delete-confirmation behind
/// `#if os(macOS)`. The scheduler/sensor observers (iOS-app-target only, plan
/// 36) drive the post-mutation `replan()`; on macOS `replan()` is a no-op and
/// CloudKit + the iPhone's RemoteChangeObserver do the replanning (plan 47).
struct GroupsList: View {
    @Environment(\.modelContext) private var context
    @Environment(ThemeStore.self) private var themeStore
    // The notification scheduler and the sensor observers live in the iOS app
    // target only — the Mac has no scheduler or sensor providers (plan 36). On
    // macOS a group edit just WRITES the PromptGroup fields; CloudKit syncs them
    // and the iPhone's RemoteChangeObserver replans (plan 47). So every use of
    // these is `#if os(iOS)`-guarded and `replan()` is a no-op on macOS.
    #if os(iOS)
    @Environment(\.notificationPrefs) private var notificationPrefs
    @Environment(NotificationScheduler.self) private var scheduler
    @Environment(AwakeStore.self) private var awakeStore
    @Environment(WorkoutEndObserver.self) private var workoutEndObserver
    @Environment(VisitObserver.self) private var visitObserver
    @Environment(CalendarEventObserver.self) private var calendarEventObserver
    #endif
    @Query(sort: \PromptGroup.sortOrder) private var groups: [PromptGroup]
    #if os(macOS)
    // Mac-only safety net: mirrors QuestionsList's confirmation dialog before
    // deleting a group — the shared list's swipe/edit-mode delete
    // (`delete(at:)` below) has no confirmation, so this stays desktop-only.
    @State private var pendingDelete: PromptGroup?
    #endif

    /// The selected group's `uniqueIdentifier`, owned by the host. The host
    /// decides what a selection means: `PromptGroupsView` pushes the editor via
    /// `.navigationDestination(item:)`; the future shell shows it in a detail
    /// column.
    @Binding var selection: String?

    /// Fix wave 1 (shell-readiness): the "ADD A GROUP…" row used to carry its
    /// own `NavigationLink` push, which assumed an ambient `NavigationStack`.
    /// That's fine for the iPhone push host but inert inside a
    /// `NavigationSplitView` sidebar column, so — like `QuestionsList`'s
    /// `onAddQuestion` — the action is hoisted to a closure the host wires up
    /// however navigation works for it.
    var onAddGroup: () -> Void

    init(selection: Binding<String?>, onAddGroup: @escaping () -> Void) {
        _selection = selection
        self.onAddGroup = onAddGroup
    }

    private var theme: Theme { themeStore.theme }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List(selection: $selection) {
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
                        .tag(group.uniqueIdentifier)
                        .listRowBackground(Color.white.opacity(0.12))
                        #if os(macOS)
                        // Mac-only safety net: MacPromptGroupsView (retired)
                        // offered a confirmation dialog before deleting a
                        // group; the shared list's swipe/edit-mode delete
                        // (below) has no confirmation, so this stays
                        // desktop-only.
                        .contextMenu {
                            Button("Delete", role: .destructive) { pendingDelete = group }
                        }
                        #endif
                }
                .onMove(perform: move)
                // Fix wave 1 (shell-readiness): a focused-selection + Delete key
                // in a macOS sidebar could otherwise fire an UNCONFIRMED delete
                // via this same List's edit-mode/swipe action. macOS deletion
                // stays routed exclusively through the confirmationDialog/
                // contextMenu below (`#if os(macOS)`), so this list-level delete
                // is iOS-only.
                #if os(iOS)
                .onDelete(perform: delete)
                #endif

                // Fix wave 1 (shell-readiness): a plain `Button` routed to a
                // host-owned closure — mirrors `QuestionsList`'s `onAddQuestion`
                // — instead of a `NavigationLink`, so this list stays a pure
                // list+selection with no ambient `NavigationStack` assumption.
                Button {
                    onAddGroup()
                } label: {
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
            #if os(macOS)
            // MacCatalogUITests proves a List-level identifier DOES survive
            // AppKit's AXOutline translation — CatalogListView's
            // `mac-catalog-list` sits directly on its List. Mirror that
            // proven placement here instead of the unproven bare-ZStack id.
            .accessibilityIdentifier("mac-groups-list")
            #endif
        }
        .navigationTitle("Prompt Groups")
        .accessibilityIdentifier("prompt-groups")
        .inlineNavTitleOnPhone()
        .darkNavBarOnPhone()
        .toolbar {
            // `EditButton` doesn't exist on macOS — its List already supports
            // drag-reorder/swipe-delete without an edit-mode toggle (the pattern
            // the retired MacPromptGroupsView shipped with), so this is iOS-only,
            // not a dropped capability.
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .tint(.white)
            }
            #endif
        }
        #if os(macOS)
        // Mac-only safety net: mirrors QuestionsList's confirmation dialog
        // before deleting a group — the shared list's swipe/edit-mode delete
        // (`delete(at:)` below, via `EditButton`/swipe on iOS) has no
        // confirmation, so this stays desktop-only.
        .confirmationDialog(
            "Delete this group?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { group in
            Button("Delete", role: .destructive) {
                deleteGroup(group)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This prompt group will be removed. Its questions are kept.")
        }
        #endif
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

    /// Deletes a single group — shared by the swipe/edit-mode delete
    /// (`delete(at:)`) and the Mac confirmation dialog's confirm action.
    private func deleteGroup(_ group: PromptGroup) {
        context.delete(group)
        try? context.save()
        replan()
    }

    private func delete(at offsets: IndexSet) {
        for offset in offsets {
            deleteGroup(groups[offset])
        }
    }

    private func replan() {
        // No scheduler or observers on macOS (plan 36): the save above is enough
        // — CloudKit syncs the change and the iPhone's RemoteChangeObserver
        // replans (plan 47). On iOS, replan the local schedule immediately.
        #if os(iOS)
        scheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
        workoutEndObserver.refresh()
        visitObserver.refresh()
        calendarEventObserver.refresh()
        #endif
    }
}

/// iPhone / Settings push-host over `GroupsList` (plan 12). Reached via a
/// `NavigationLink` from `SettingsView` (iPhone) and wrapped in
/// `NavigationStack { PromptGroupsView() }` by `MacRootView` (Mac), so it
/// deliberately does NOT create its own `NavigationStack` — it relies on that
/// ambient stack and registers a `.navigationDestination(item:)` that pushes
/// the editor for the selected group. Same entry point and same user-visible
/// behavior as before Task 3.3.
struct PromptGroupsView: View {
    @Query(sort: \PromptGroup.sortOrder) private var groups: [PromptGroup]
    @State private var selection: String?

    /// Fix wave 1 (shell-readiness): "ADD A GROUP…" used to be its own
    /// `NavigationLink(destination: PromptGroupEditorView(group: nil))` inside
    /// the list. Now that the row is a `Button` routed through `onAddGroup`,
    /// this state-driven flag plus a second `.navigationDestination(isPresented:)`
    /// reproduces the identical push — kept separate from `selection`/
    /// `.navigationDestination(item:)` so a new group never collides with an
    /// existing one's identifier.
    @State private var isAddingGroup = false

    var body: some View {
        GroupsList(
            selection: $selection,
            onAddGroup: { isAddingGroup = true }
        )
        .navigationDestination(item: $selection) { identifier in
            // A selection can outlive its group (deleted while selected); guard
            // the lookup so a stale id never opens the new-group editor
            // (`PromptGroupEditorView(group: nil)`).
            if let group = groups.first(where: { $0.uniqueIdentifier == identifier }) {
                PromptGroupEditorView(group: group)
            }
        }
        .navigationDestination(isPresented: $isAddingGroup) {
            PromptGroupEditorView(group: nil)
        }
    }
}

struct PromptGroupRowView: View {
    // The "won't fire" hints below read the iOS sensor observers, which don't
    // exist on macOS (plan 36). The Mac never owns firing or sensor permissions
    // — the paired iPhone does — so the hints (and these observers) are iOS-only.
    #if os(iOS)
    @Environment(VisitObserver.self) private var visitObserver
    @Environment(MonitorObserver.self) private var monitorObserver
    @Environment(CalendarEventObserver.self) private var calendarEventObserver
    #endif
    let group: PromptGroup
    let onChange: () -> Void

    var body: some View {
        // Plain, selectable row content — no `NavigationLink`. Navigation is
        // driven by the enclosing `List(selection:)` + the host's
        // `.navigationDestination(item:)` (Task 3.3), which lets the same row
        // act as a push on iPhone and a detail-column selection in the shell
        // (the QuestionRowView precedent from Task 3.2).
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
                // These "won't fire" hints reflect iOS sensor-permission
                // state, which the Mac neither owns nor can read (plan 36) —
                // iOS-only.
                #if os(iOS)
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
                #endif
            }

            Spacer()

            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .tint(.white.opacity(0.4))
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

    #if os(macOS)
    /// Sensor/schedule kinds that run on device sensors: configurable on the
    /// Mac, but they FIRE on the paired iPhone (plan 36). Drives the Mac's
    /// "fires on your iPhone" note (`mac-group-ios-only-note`).
    var isDeviceOnly: Bool {
        switch self {
        case .everyNHours, .timesPerDay, .dailyAt: false
        case .workoutEnd, .visitArrival, .calendarEventEnd, .placeTrigger, .beaconTrigger: true
        }
    }

    /// Beacon groups can only be VIEWED (not created) on the Mac — there's no
    /// beacon scanner (issue #84). Places ARE creatable via the shared place
    /// search (plan 50), so only beacon is "trigger-only" on the Mac.
    var isMacTriggerOnly: Bool { self == .beaconTrigger }
    #endif
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
    @Environment(ThemeStore.self) private var themeStore
    // Scheduler + sensor observers are iOS-only (plan 36). On macOS this editor
    // just writes the PromptGroup fields; the paired iPhone replans on the
    // synced change, and the sensor-permission asks / auth hints below are
    // suppressed (there's nothing to authorize on the Mac).
    #if os(iOS)
    @Environment(\.notificationPrefs) private var notificationPrefs
    @Environment(NotificationScheduler.self) private var scheduler
    @Environment(AwakeStore.self) private var awakeStore
    @Environment(WorkoutEndObserver.self) private var workoutEndObserver
    @Environment(VisitObserver.self) private var visitObserver
    @Environment(MonitorObserver.self) private var monitorObserver
    @Environment(CalendarEventObserver.self) private var calendarEventObserver
    #endif
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

    #if os(macOS)
    /// A `.calendars([...])` rule references the phone's calendars, which the
    /// Mac can't enumerate — preserved read-only when already set (plan 47), so
    /// editing such a group on the Mac never drops its calendar selection.
    private let pinnedCalendarIDs: [String]?
    /// A BEACON trigger (plan 45) the Mac can't reconfigure (no scanner, issue
    /// #84) — preserved verbatim on save so viewing a beacon group here never
    /// drops its iPhone trigger. Places are NOT locked (plan 50 place search).
    private let lockedTriggerSchedule: GroupSchedule?
    #endif

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
        #if os(macOS)
        // A phone-set specific-calendars rule / an existing beacon trigger the
        // Mac can't reconfigure — captured here and preserved on save.
        var pinned: [String]? = nil
        var lockedTrigger: GroupSchedule? = nil
        #endif
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
                #if os(iOS)
                matchKind = .calendars; calendarIDs = ids
                #else
                // The Mac can't read the phone's calendars — keep the rule
                // pinned and default the visible match to "all events".
                matchKind = .allEvents; pinned = ids
                #endif
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
            #if os(macOS)
            // View-only on the Mac (no beacon scanner, issue #84) — preserve the
            // iPhone-set trigger verbatim on save.
            lockedTrigger = group?.schedule
            #endif
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
        #if os(macOS)
        pinnedCalendarIDs = pinned
        lockedTriggerSchedule = lockedTrigger
        #endif
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
        .inlineNavTitleOnPhone()
        .darkNavBarOnPhone()
        .toolbar {
            // `.primaryAction` resolves to the nav-bar trailing slot on iOS and
            // the window toolbar on macOS (the QuestionEditorView precedent) —
            // one placement for both platforms.
            ToolbarItem(placement: .primaryAction) {
                // A group with no questions would fire prompts that open an
                // empty survey — require at least one question to save.
                Button("Save") { save() }
                    .disabled(questionIDs.isEmpty || scheduleValidationMessage != nil)
                    #if os(macOS)
                    .keyboardShortcut(.defaultAction)
                    #endif
                    .accessibilityIdentifier("group-save")
            }
        }
    }

    /// Multi-select membership over enabled questions. Selection order IS
    /// the survey order: toggling on appends, toggling off removes.
    private var questionsSection: some View {
        let enabledQuestions = questions.filter(\.isEnabled)
        return Section {
            if enabledQuestions.isEmpty {
                // A user with every question disabled can't add any here (and
                // Save stays disabled while `questionIDs` is empty) — say so
                // instead of showing a silently-empty section.
                Text("No enabled questions to add.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityIdentifier("group-questions-empty")
            } else {
                ForEach(enabledQuestions, id: \.uniqueIdentifier) { question in
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
            }
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
                ForEach(availableKinds) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .foregroundStyle(.white)
            .tint(.white.opacity(0.7))
            .accessibilityIdentifier("group-schedule-kind")

            #if os(macOS)
            // The Mac has no scheduler/sensors (plan 36): sensor-driven kinds are
            // configured here but FIRE on the paired iPhone. This note carries
            // the retired MacPromptGroupsView's `mac-group-ios-only-note` so a
            // Mac user knows which schedules are Mac-settable vs iPhone-run.
            if scheduleKind.isDeviceOnly {
                Text("Fires on your iPhone — this schedule uses device sensors "
                    + "and runs on iOS/watch only. You can configure it here.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityIdentifier("mac-group-ios-only-note")
            }
            #endif

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
                #if os(iOS)
                if !visitObserver.hasAlwaysAuthorization {
                    visitAuthorizationHint
                }
                #endif
            case .calendarEventEnd:
                Text("Fires a prompt when a matching calendar event ends — "
                    + "e.g. “How was the meeting?”. Needs full calendar access "
                    + "to read your events.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                #if os(macOS)
                // A phone-set specific-calendars rule the Mac can't enumerate —
                // shown so the user knows it's preserved (default match "all
                // events" keeps it; changing the match type overrides it).
                if let pinnedCalendarIDs {
                    Text("Matching \(pinnedCalendarIDs.count) specific calendar"
                        + "\(pinnedCalendarIDs.count == 1 ? "" : "s") chosen on your "
                        + "iPhone. Change the match type to override.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
                #endif
                Picker("Match", selection: $calendarMatchKind) {
                    ForEach(calendarMatchKinds) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .foregroundStyle(.white)
                .tint(.white.opacity(0.7))
                .accessibilityIdentifier("group-calendar-match")
                // "Specific calendars" needs to read the user's calendars, which
                // the Mac can't (plan 36) — so its picker option and selection
                // list are iOS-only (a phone-set rule is preserved via pinning).
                #if os(iOS)
                if calendarMatchKind == .calendars {
                    calendarSelectionList
                }
                #endif
                if calendarMatchKind == .titleContains {
                    TextField("Title contains", text: $titleFilter)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .accessibilityIdentifier("group-calendar-title")
                }
                #if os(iOS)
                if !calendarEventObserver.hasFullAccess {
                    calendarAuthorizationHint
                }
                #else
                Text("Matching by specific calendars must be set on your iPhone "
                    + "(the Mac can't read your calendars).")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                #endif
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
                #if os(iOS)
                if !monitorObserver.hasAlwaysAuthorization {
                    monitorAuthorizationHint
                }
                #endif
            case .beaconTrigger:
                #if os(iOS)
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
                #else
                // The Mac can't scan for a beacon (issue #84), so a beacon group
                // is view-only here — its iPhone-set trigger is preserved verbatim
                // on save (draftSchedule → lockedTriggerSchedule). Name/questions
                // stay editable. Carries the retired Mac's `mac-group-trigger-note`.
                Text("Triggered by a beacon set on your iPhone. Configure the "
                    + "beacon on iOS; you can still edit this group's questions "
                    + "and name here.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityIdentifier("mac-group-trigger-note")
                #endif
            }
        } header: {
            sectionHeader("SCHEDULE")
        }
        .listRowBackground(Color.white.opacity(0.12))
        // Editor-contextual permission asks (plans 16 + 31): the ONLY places
        // the app ever asks — picking the visit/calendar schedule is the
        // moment the section text above has just explained why. Never part
        // of onboarding. iOS-only: the Mac has no sensor permissions to ask
        // for (plan 36). On sync, the iPhone's observers only RECONCILE
        // against an already-granted permission — they never prompt. So a
        // Mac-created sensor group schedules once the iPhone already has the
        // permission; otherwise the iPhone shows its existing "won't fire"
        // hint (`PromptGroupRowView`, same as an iPhone-created group missing
        // permission) rather than asking for it.
        #if os(iOS)
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
        #endif
    }

    /// Schedule kinds offered in the editor's picker. On the Mac, beacon
    /// triggers can't be created (no scanner, issue #84) — they appear only when
    /// editing a group that already has one (matching the retired Mac editor).
    private var availableKinds: [EditableScheduleKind] {
        #if os(macOS)
        EditableScheduleKind.allCases.filter { !$0.isMacTriggerOnly || $0 == scheduleKind }
        #else
        EditableScheduleKind.allCases
        #endif
    }

    /// Calendar match kinds offered in the picker. The Mac can't read the user's
    /// calendars, so "Specific calendars" is iOS-only — a phone-set rule is
    /// preserved through `pinnedCalendarIDs` instead.
    private var calendarMatchKinds: [CalendarMatchKindDraft] {
        #if os(macOS)
        CalendarMatchKindDraft.allCases.filter { $0 != .calendars }
        #else
        CalendarMatchKindDraft.allCases
        #endif
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
            #if os(iOS)
            guard UUID(uuidString: beaconUUID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            else { return "Enter a valid beacon UUID (e.g. E2C56DB5-DFFB-48D2-B060-D0F5A71096E0)." }
            for value in [beaconMajor, beaconMinor] where !value.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let number = Int(value), (0...65_535).contains(number)
                else { return "Major and minor must be whole numbers from 0 to 65535." }
            }
            return nil
            #else
            // Beacon is view-only on the Mac; the phone-set trigger is preserved
            // unchanged (issue #84), so there's nothing to validate.
            return nil
            #endif
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
            #if os(iOS)
            .textInputAutocapitalization(.words)
            #endif
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
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .foregroundStyle(.white).tint(.white)
                .accessibilityIdentifier("group-place-latitude")
            TextField("Longitude", text: $placeLongitude)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
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
    /// the prompt). iOS-only: reads `MonitorObserver`, which is absent on macOS.
    #if os(iOS)
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
    /// explains why. iOS-only: the Mac can't enumerate the user's calendars.
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
    #endif

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
            #if os(iOS)
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
            #else
            // View-only on the Mac (issue #84): preserve the iPhone-set beacon
            // trigger verbatim. Unreachable for a fresh group (beacon isn't in
            // the Mac picker), so the `.disabled` fallback is purely defensive.
            lockedTriggerSchedule ?? .disabled
            #endif
        }
    }

    /// Commits the calendar drafts to a rule. An empty (trimmed) title
    /// filter normalizes to `.allEvents` on save (plan-31 design decision:
    /// degenerate configs are prevented here; `.calendars([])` remains
    /// storable and matches nothing — fails safe).
    private var draftCalendarRule: CalendarEventMatchRule {
        #if os(macOS)
        // Preserve a phone-set specific-calendars rule unless the user picked a
        // different match type here (the Mac can't enumerate calendars, so it
        // can't rebuild the selection — only keep or replace it).
        if let pinnedCalendarIDs, calendarMatchKind == .allEvents,
           titleFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .calendars(pinnedCalendarIDs)
        }
        #endif
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
        // On macOS the save is enough — CloudKit syncs it and the iPhone's
        // RemoteChangeObserver replans (plan 47). iOS replans/refreshes locally.
        #if os(iOS)
        scheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
        workoutEndObserver.refresh()
        visitObserver.refresh()
        monitorObserver.refresh()
        calendarEventObserver.refresh()
        #endif
        dismiss()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }
}
