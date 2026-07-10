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
                        + "or when you arrive somewhere. "
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
    }
}

struct PromptGroupRowView: View {
    @Environment(VisitObserver.self) private var visitObserver
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
                }

                Spacer()

                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .tint(.white.opacity(0.4))
            }
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

extension GroupSchedule {
    /// One-line schedule readout for the groups list.
    var summary: String {
        switch self {
        case .everyNHours(let hours):
            "Every \(hours)h"
        case .timesPerDay(let count, _):
            "\(count)× per day"
        case .dailyAt(let times):
            times.isEmpty
                ? "Daily"
                : "Daily at " + times.map(PromptGroup.timeString(fromComponents:)).joined(separator: ", ")
        case .workoutEnd:
            "When a workout ends"
        case .visitArrival:
            "When I arrive somewhere"
        case .disabled:
            "Unknown schedule"
        }
    }
}

// MARK: - Editor

/// The schedule-kind rows of the editor picker. `.disabled` (unknown raw) is
/// deliberately not offered; editing such a group defaults the picker to
/// timesPerDay and saving overwrites the unknown kind.
private enum EditableScheduleKind: String, CaseIterable, Identifiable {
    case everyNHours, timesPerDay, dailyAt, workoutEnd, visitArrival
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .everyNHours: "Every N hours"
        case .timesPerDay: "Times per day"
        case .dailyAt: "Daily at times"
        case .workoutEnd: "When a workout ends"
        case .visitArrival: "When I arrive somewhere"
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
    @State private var isEnabled: Bool
    @State private var newTime = Date()

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
        case .disabled, nil:
            break
        }
        _scheduleKind = State(initialValue: kind)
        _everyHours = State(initialValue: hours)
        _timesPerDay = State(initialValue: count)
        _distribution = State(initialValue: dist)
        _dailyTimes = State(initialValue: times)
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("group-name")
                } header: {
                    sectionHeader("NAME")
                }
                .listRowBackground(Color.white.opacity(0.12))

                questionsSection
                scheduleSection

                Section {
                    Toggle("Enabled", isOn: $isEnabled)
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
                    .disabled(questionIDs.isEmpty)
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
            .accessibilityIdentifier("group-schedule-kind")

            switch scheduleKind {
            case .everyNHours:
                Stepper("Every \(everyHours)h", value: $everyHours, in: 1...12)
                    .accessibilityIdentifier("group-every-hours")
            case .timesPerDay:
                Stepper("\(timesPerDay)× per day", value: $timesPerDay, in: 1...12)
                    .accessibilityIdentifier("group-times-per-day")
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
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    DatePicker("Add a time", selection: $newTime, displayedComponents: .hourAndMinute)
                    Button("ADD") { addDailyTime() }
                        .font(.caption.weight(.semibold))
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
            }
        } header: {
            sectionHeader("SCHEDULE")
        }
        .listRowBackground(Color.white.opacity(0.12))
        // Editor-contextual Always upgrade (plan 16): the ONLY place the app
        // ever asks — picking the visit schedule is the moment the section
        // text above has just explained why. Never part of onboarding.
        .onChange(of: scheduleKind) { _, newKind in
            if newKind == .visitArrival, !visitObserver.hasAlwaysAuthorization {
                Task { await visitObserver.requestAlwaysAuthorization() }
            }
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
        dismiss()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }
}
