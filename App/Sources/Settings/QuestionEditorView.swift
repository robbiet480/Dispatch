import DispatchKit
import SwiftData
import SwiftUI

struct QuestionEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    @Query private var responses: [Response]
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// nil ⇒ creating a new question.
    let question: Question?

    @State private var prompt: String
    @State private var type: QuestionType
    @State private var choices: [String]
    @State private var placeholder: String
    @State private var kinds: Set<ReportKind>
    @State private var logAsStateOfMind: Bool
    @State private var visualization: VisualizationStyle?
    /// Per-keystroke text stays in this local @State (see LocalTextEditorField's
    /// doc comment in QuestionPageView for the keyboard-garbling lesson).
    @State private var defaultAnswer: String
    @State private var allowsMultipleSelection: Bool
    /// Number input style (plan 21) + its contextual config fields. Config
    /// text is validated like the default answer: finite Doubles, min < max,
    /// step > 0 — invalid entries are simply not persisted.
    @State private var inputStyle: NumberInputStyle
    @State private var inputMin: String
    @State private var inputMax: String
    @State private var inputStep: String

    private var theme: Theme { themeStore.theme }

    init(question: Question?) {
        self.question = question
        _prompt = State(initialValue: question?.prompt ?? "")
        _type = State(initialValue: question?.type ?? .tokens)
        _choices = State(initialValue: question?.choices ?? [])
        _placeholder = State(initialValue: question?.placeholderString ?? "")
        _kinds = State(initialValue: Set(question?.reportKinds ?? [.regular]))
        _logAsStateOfMind = State(initialValue: question?.stateOfMindKind != nil)
        _visualization = State(initialValue: question?.visualization)
        _defaultAnswer = State(initialValue: question?.defaultAnswerString ?? "")
        _allowsMultipleSelection = State(initialValue: question?.allowsMultipleSelection ?? true)
        _inputStyle = State(initialValue: question?.inputStyle ?? .textField)
        _inputMin = State(initialValue: Self.configText(question?.inputMin))
        _inputMax = State(initialValue: Self.configText(question?.inputMax))
        _inputStep = State(initialValue: Self.configText(question?.inputStep))
    }

    /// Seeds a config text field from a stored Double — integer-formatted
    /// when whole so "10.0" never shows for a value the user typed as "10".
    private static func configText(_ value: Double?) -> String {
        guard let value else { return "" }
        if value.truncatingRemainder(dividingBy: 1) == 0, value.magnitude < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }

    private var supportsStateOfMind: Bool {
        type == .multipleChoice || type == .yesNo
    }

    /// Existing questions cannot change type once responses reference them —
    /// changing shape would orphan already-recorded answers.
    private var isTypeLocked: Bool {
        guard let question else { return false }
        return responses.contains { response in
            if let responseQuestionIdentifier = response.questionIdentifier {
                return responseQuestionIdentifier == question.uniqueIdentifier
            }
            // Legacy imports have no questionIdentifier — fall back to prompt equality.
            return response.questionPrompt == question.prompt
        }
    }

    private var canSave: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !kinds.isEmpty
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            Form {
                Section {
                    TextField("Prompt", text: $prompt)
                } header: {
                    sectionHeader("PROMPT")
                }
                .listRowBackground(Color.white.opacity(0.12))

                Section {
                    Picker("Type", selection: $type) {
                        ForEach(QuestionType.allCases, id: \.self) { candidate in
                            Text(candidate.displayName).tag(candidate)
                        }
                    }
                    .accessibilityIdentifier("question-type")
                    .disabled(isTypeLocked)
                } header: {
                    sectionHeader("TYPE")
                } footer: {
                    if isTypeLocked {
                        Text("Type is locked because this question already has responses.")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .listRowBackground(Color.white.opacity(0.12))

                if type == .multipleChoice {
                    Section {
                        NavigationLink {
                            ChoiceOptionsEditorView(choices: $choices,
                                                    allowsMultipleSelection: $allowsMultipleSelection,
                                                    theme: theme)
                        } label: {
                            HStack {
                                Text(choicesSummary)
                                    .lineLimit(1)
                                Spacer()
                                Text("EDIT")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .accessibilityIdentifier("choice-editor")
                    } header: {
                        sectionHeader("CHOICES")
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                }

                if !VisualizationStyle.compatibleStyles(for: type).isEmpty {
                    Section {
                        Picker("Visualization", selection: $visualization) {
                            Text("Automatic (\(automaticStyleName))").tag(VisualizationStyle?.none)
                            ForEach(VisualizationStyle.compatibleStyles(for: type), id: \.self) { style in
                                Text(style.displayName).tag(VisualizationStyle?.some(style))
                            }
                        }
                        .accessibilityIdentifier("visualization-picker")
                    } header: {
                        sectionHeader("VISUALIZATION")
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                }

                if type == .number {
                    Section {
                        Picker("Input style", selection: $inputStyle) {
                            ForEach(NumberInputStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .accessibilityIdentifier("input-style")
                        if configFields.min {
                            TextField("Minimum", text: $inputMin)
                                .keyboardType(.decimalPad)
                                .accessibilityIdentifier("input-min")
                        }
                        if configFields.max {
                            TextField("Maximum", text: $inputMax)
                                .keyboardType(.decimalPad)
                                .accessibilityIdentifier("input-max")
                        }
                        if configFields.step {
                            TextField("Step", text: $inputStep)
                                .keyboardType(.decimalPad)
                                .accessibilityIdentifier("input-step")
                        }
                    } header: {
                        sectionHeader("INPUT STYLE")
                    } footer: {
                        if inputStyle != .textField {
                            Text("Blank fields use the style's defaults. Invalid values (minimum not below maximum, step of zero) are ignored.")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.12))

                    Section {
                        TextField("Value for empty responses", text: $defaultAnswer)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("default-answer-field")
                    } header: {
                        sectionHeader("DEFAULT ANSWER")
                    } footer: {
                        Text("Filed automatically when you leave this question empty.")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                }

                Section {
                    TextField("Placeholder", text: $placeholder)
                } header: {
                    sectionHeader("PLACEHOLDER")
                }
                .listRowBackground(Color.white.opacity(0.12))

                if supportsStateOfMind {
                    Section {
                        Toggle("Log as State of Mind", isOn: $logAsStateOfMind)
                            .tint(.white)
                    } header: {
                        sectionHeader("APPLE HEALTH")
                    } footer: {
                        Text("When on, each answer to this question also logs a State of Mind entry to Apple Health.")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                }

                Section {
                    // Three fixed chips in a row clip at accessibility
                    // Dynamic Type sizes — stack vertically there instead.
                    scheduleChipLayout {
                        scheduleChip("WAKE", icon: "sunrise.fill", kind: .wake, identifier: "schedule-wake")
                        scheduleChip("DAY", icon: "sun.max.fill", kind: .regular, identifier: "schedule-day")
                        scheduleChip("SLEEP", icon: "moon.fill", kind: .sleep, identifier: "schedule-sleep")
                    }
                    .listRowBackground(Color.clear)
                } header: {
                    sectionHeader("SHOW ON")
                } footer: {
                    Text("At least one report kind is required.")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(question == nil ? "Add Question" : "Edit Question")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
    }

    /// Which config fields the chosen input style exposes (spec §Styles):
    /// slider/dial/stepper take min/max/step, tapCounter an optional max,
    /// scale its min/max point range, textField nothing.
    private var configFields: (min: Bool, max: Bool, step: Bool) {
        switch inputStyle {
        case .textField: (min: false, max: false, step: false)
        case .slider, .stepper, .dial: (min: true, max: true, step: true)
        case .tapCounter: (min: false, max: true, step: false)
        case .scale: (min: true, max: true, step: false)
        }
    }

    private var choicesSummary: String {
        let cleaned = choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? "Add an option…" : cleaned.joined(separator: ", ")
    }

    /// The name of the style the automatic default would pick for `type`,
    /// shown in the picker's "Automatic" row.
    private var automaticStyleName: String {
        VisualizationStyle.compatibleStyles(for: type).first?.displayName ?? "None"
    }

    /// Horizontal row of schedule chips normally; a leading-aligned vertical
    /// stack at accessibility Dynamic Type sizes (three chips no longer fit
    /// side by side without clipping).
    @ViewBuilder
    private func scheduleChipLayout(@ViewBuilder content: () -> some View) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10, content: content)
        } else {
            HStack(spacing: 10, content: content)
        }
    }

    /// A capsule chip that toggles membership of `kind` in the schedule set —
    /// filled when selected, multi-select, ≥1 enforced by `canSave`.
    private func scheduleChip(_ title: String, icon: String, kind: ReportKind, identifier: String) -> some View {
        let isSelected = kinds.contains(kind)
        return Button {
            toggle(kind)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .imageScale(.small)
                    .accessibilityHidden(true) // decorative; the title names the chip
                Text(title)
                    .font(.caption.weight(.semibold))
                    .kerning(1.0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.12),
                        in: Capsule())
            .foregroundStyle(isSelected ? Color.themeBackground(theme) : .white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title.capitalized) reports")
        .accessibilityHint("Toggles whether this question is asked on \(title.lowercased()) reports.")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func toggle(_ kind: ReportKind) {
        if kinds.contains(kind) {
            kinds.remove(kind)
        } else {
            kinds.insert(kind)
        }
    }

    private func save() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPlaceholder = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedChoices = choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let orderedKinds = ReportKind.allCases.filter { kinds.contains($0) }

        let stateOfMindKind = (supportsStateOfMind && logAsStateOfMind) ? "momentaryEmotion" : nil

        if let question {
            question.prompt = trimmedPrompt
            if !isTypeLocked {
                question.type = type
            }
            question.choices = question.type == .multipleChoice ? cleanedChoices : []
            question.placeholderString = trimmedPlaceholder.isEmpty ? nil : trimmedPlaceholder
            question.reportKinds = orderedKinds
            question.stateOfMindKind = stateOfMindKind
            applyParityFields(to: question)
        } else {
            let newQuestion = QuestionAdmin.makeQuestion(
                prompt: trimmedPrompt,
                type: type,
                choices: type == .multipleChoice ? cleanedChoices : [],
                placeholder: trimmedPlaceholder.isEmpty ? nil : trimmedPlaceholder,
                kinds: orderedKinds,
                after: questions
            )
            newQuestion.stateOfMindKind = stateOfMindKind
            applyParityFields(to: newQuestion)
            context.insert(newQuestion)
        }

        try? context.save()
        dismiss()
    }

    /// Writes the plan-11 parity fields, keeping the schema's nil semantics:
    /// visualization only sticks when compatible with the saved type; default
    /// answer only applies to number questions; the multi-select flag is only
    /// recorded for multiple-choice questions (raw nil elsewhere preserves
    /// pre-flag behavior).
    private func applyParityFields(to target: Question) {
        let savedType = target.type
        target.visualization = visualization?.isCompatible(with: savedType) == true ? visualization : nil
        // Only persist a default answer that actually parses as a FINITE
        // number — junk text or "inf"/"nan" would otherwise be filed as a
        // numeric response (build-5 review fix).
        let trimmedDefault = defaultAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        let isValidDefault = !trimmedDefault.isEmpty && Double(trimmedDefault)?.isFinite == true
        target.defaultAnswerString = (savedType == .number && isValidDefault) ? trimmedDefault : nil
        if savedType == .multipleChoice {
            target.allowsMultipleSelection = allowsMultipleSelection
        } else {
            target.allowsMultipleSelectionRaw = nil
        }
        applyInputStyleFields(to: target, savedType: savedType)
    }

    /// Writes the plan-21 input-style fields. Only number questions carry a
    /// style (`.textField` writes raw nil via the computed setter); config
    /// values follow the default-answer validation pattern — finite Doubles
    /// only, step > 0, min < max, fields the style doesn't expose are
    /// cleared, and anything invalid is simply not persisted (nil = the
    /// style's defaults).
    private func applyInputStyleFields(to target: Question, savedType: QuestionType) {
        guard savedType == .number else {
            target.inputStyle = .textField
            target.inputMin = nil
            target.inputMax = nil
            target.inputStep = nil
            return
        }
        target.inputStyle = inputStyle
        var minValue = configFields.min ? parseConfig(inputMin) : nil
        var maxValue = configFields.max ? parseConfig(inputMax) : nil
        let stepValue = configFields.step ? parseConfig(inputStep).flatMap { $0 > 0 ? $0 : nil } : nil
        if let low = minValue, let high = maxValue, low >= high {
            // An inverted/empty range is invalid as a pair — persist neither.
            minValue = nil
            maxValue = nil
        }
        target.inputMin = minValue
        target.inputMax = maxValue
        target.inputStep = stepValue
    }

    /// Parses a config text field to a FINITE Double, or nil (same rule as
    /// the default answer — junk text or "inf"/"nan" must not persist).
    private func parseConfig(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }
}

extension NumberInputStyle {
    var displayName: String {
        switch self {
        case .textField: "Text Field"
        case .slider: "Slider"
        case .stepper: "Stepper"
        case .dial: "Dial"
        case .tapCounter: "Tap Counter"
        case .scale: "Rating Scale"
        }
    }
}

extension ReportKind {
    var displayName: String {
        switch self {
        case .regular: "Regular"
        case .wake: "Wake"
        case .sleep: "Sleep"
        }
    }
}
