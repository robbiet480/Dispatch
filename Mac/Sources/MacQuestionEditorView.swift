import DispatchKit
import SwiftData
import SwiftUI

/// Plan 47 (issue #57): the Mac question editor — create or edit a question's
/// prompt, type, choices, input configuration, report kinds, and enabled
/// state. Mirrors the iOS `QuestionEditorView` semantics (type locks once
/// responses exist; number-only input config; per-type choices) rebuilt
/// Mac-native. Also offers catalog submission (issue #58).
struct MacQuestionEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    @Query private var responses: [Response]

    let question: Question?

    @State private var prompt: String
    @State private var type: QuestionType
    @State private var choices: [String]
    @State private var placeholder: String
    @State private var kinds: Set<ReportKind>
    @State private var logAsStateOfMind: Bool
    @State private var defaultAnswer: String
    @State private var allowsMultipleSelection: Bool
    @State private var inputStyle: NumberInputStyle
    @State private var inputMin: String
    @State private var inputMax: String
    @State private var inputStep: String
    @State private var isEnabled: Bool
    @State private var showingCatalogSubmit = false
    @State private var catalogStore = CatalogStore()

    init(question: Question?) {
        self.question = question
        _prompt = State(initialValue: question?.prompt ?? "")
        _type = State(initialValue: question?.type ?? .tokens)
        _choices = State(initialValue: question?.choices ?? [])
        _placeholder = State(initialValue: question?.placeholderString ?? "")
        _kinds = State(initialValue: Set(question?.reportKinds ?? [.regular]))
        _logAsStateOfMind = State(initialValue: question?.stateOfMindKind != nil)
        _defaultAnswer = State(initialValue: question?.defaultAnswerString ?? "")
        _allowsMultipleSelection = State(initialValue: question?.allowsMultipleSelection ?? true)
        _inputStyle = State(initialValue: question?.inputStyle ?? .textField)
        _inputMin = State(initialValue: Self.configText(question?.inputMin))
        _inputMax = State(initialValue: Self.configText(question?.inputMax))
        _inputStep = State(initialValue: Self.configText(question?.inputStep))
        _isEnabled = State(initialValue: question?.isEnabled ?? true)
    }

    private var isTypeLocked: Bool {
        guard let question else { return false }
        return responses.contains { response in
            if let identifier = response.questionIdentifier {
                return identifier == question.uniqueIdentifier
            }
            return response.questionPrompt == question.prompt
        }
    }

    private var supportsStateOfMind: Bool { type == .multipleChoice || type == .yesNo }

    private var canSave: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !kinds.isEmpty
    }

    private var configFields: (min: Bool, max: Bool, step: Bool) { inputStyle.exposedConfigFields }

    private var isCatalogValid: Bool {
        CatalogValidation.validate(
            prompt: prompt, typeRaw: type.rawValue,
            choices: type == .multipleChoice ? choices : []
        ).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Prompt") {
                    TextField("Prompt", text: $prompt, axis: .vertical)
                        .accessibilityIdentifier("mac-question-prompt")
                }

                Section("Type") {
                    Picker("Type", selection: $type) {
                        ForEach(QuestionType.allCases, id: \.self) { candidate in
                            Text(candidate.displayName).tag(candidate)
                        }
                    }
                    .disabled(isTypeLocked)
                    .accessibilityIdentifier("mac-question-type")
                    if isTypeLocked {
                        Text("Type is locked — this question already has answers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if type == .multipleChoice {
                    choicesSection
                }

                if type == .number {
                    numberSection
                }

                Section("Placeholder") {
                    TextField("Placeholder", text: $placeholder)
                }

                if supportsStateOfMind {
                    Section("Apple Health") {
                        Toggle("Log answers as State of Mind (fires on your iPhone)",
                               isOn: $logAsStateOfMind)
                    }
                }

                Section("Show on") {
                    Toggle("Wake reports", isOn: kindBinding(.wake))
                    Toggle("Day reports", isOn: kindBinding(.regular))
                    Toggle("Sleep reports", isOn: kindBinding(.sleep))
                    if kinds.isEmpty {
                        Text("At least one report kind is required.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }

                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                    Button("Submit to Catalog…") { showingCatalogSubmit = true }
                        .disabled(!isCatalogValid)
                        .accessibilityIdentifier("mac-question-submit-catalog")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .accessibilityIdentifier("mac-question-save")
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 520)
        .sheet(isPresented: $showingCatalogSubmit) {
            CatalogSubmitView(
                store: catalogStore, prompt: prompt, type: type,
                choices: type == .multipleChoice ? choices : [],
                inputStyle: type == .number ? inputStyle : .textField,
                inputMin: type == .number ? inputMin : "",
                inputMax: type == .number ? inputMax : "",
                inputStep: type == .number ? inputStep : "",
                defaultAnswer: type == .number ? defaultAnswer : "",
                placeholder: placeholder)
        }
    }

    @ViewBuilder
    private var choicesSection: some View {
        Section("Choices") {
            ForEach(choices.indices, id: \.self) { index in
                HStack {
                    TextField("Option \(index + 1)", text: Binding(
                        get: { choices.indices.contains(index) ? choices[index] : "" },
                        set: { if choices.indices.contains(index) { choices[index] = $0 } }
                    ))
                    Button {
                        choices.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Add Option") { choices.append("") }
                .accessibilityIdentifier("mac-question-add-choice")
            Toggle("Allow selecting more than one", isOn: $allowsMultipleSelection)
        }
    }

    @ViewBuilder
    private var numberSection: some View {
        Section("Input style") {
            Picker("Input style", selection: $inputStyle) {
                ForEach(NumberInputStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .accessibilityIdentifier("mac-question-input-style")
            if configFields.min {
                TextField("Minimum", text: $inputMin)
            }
            if configFields.max {
                TextField("Maximum", text: $inputMax)
            }
            if configFields.step {
                TextField("Step", text: $inputStep)
            }
            if inputStyle != .textField {
                Text("Blank fields use the style's defaults. Invalid values are ignored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Default answer") {
            TextField("Value for empty responses", text: $defaultAnswer)
        }
    }

    private func kindBinding(_ kind: ReportKind) -> Binding<Bool> {
        Binding(
            get: { kinds.contains(kind) },
            set: { on in if on { kinds.insert(kind) } else { kinds.remove(kind) } }
        )
    }

    private func save() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPlaceholder = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedChoices = choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let orderedKinds = ReportKind.allCases.filter { kinds.contains($0) }
        let stateOfMindKind = (supportsStateOfMind && logAsStateOfMind) ? "momentaryEmotion" : nil

        let target: Question
        if let question {
            target = question
            target.prompt = trimmedPrompt
            if !isTypeLocked { target.type = type }
        } else {
            target = QuestionAdmin.makeQuestion(
                prompt: trimmedPrompt, type: type,
                choices: type == .multipleChoice ? cleanedChoices : [],
                placeholder: trimmedPlaceholder.isEmpty ? nil : trimmedPlaceholder,
                kinds: orderedKinds, after: questions)
            context.insert(target)
        }
        target.choices = target.type == .multipleChoice ? cleanedChoices : []
        target.placeholderString = trimmedPlaceholder.isEmpty ? nil : trimmedPlaceholder
        target.reportKinds = orderedKinds
        target.stateOfMindKind = stateOfMindKind
        target.isEnabled = isEnabled
        applyParityFields(to: target)

        try? context.save()
        dismiss()
    }

    private func applyParityFields(to target: Question) {
        let savedType = target.type
        let trimmedDefault = defaultAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        let validDefault = !trimmedDefault.isEmpty && Double(trimmedDefault)?.isFinite == true
        target.defaultAnswerString = (savedType == .number && validDefault) ? trimmedDefault : nil
        if savedType == .multipleChoice {
            target.allowsMultipleSelection = allowsMultipleSelection
        } else {
            target.allowsMultipleSelectionRaw = nil
        }
        guard savedType == .number else {
            target.inputStyle = .textField
            target.inputMin = nil; target.inputMax = nil; target.inputStep = nil
            return
        }
        target.inputStyle = inputStyle
        var minValue = configFields.min ? NumberInputStyle.parseConfigText(inputMin) : nil
        var maxValue = configFields.max ? NumberInputStyle.parseConfigText(inputMax) : nil
        let stepValue = configFields.step
            ? NumberInputStyle.parseConfigText(inputStep).flatMap { $0 > 0 ? $0 : nil } : nil
        if let low = minValue, let high = maxValue, low >= high {
            minValue = nil; maxValue = nil
        }
        target.inputMin = minValue
        target.inputMax = maxValue
        target.inputStep = stepValue
    }

    private static func configText(_ value: Double?) -> String {
        guard let value else { return "" }
        if value.truncatingRemainder(dividingBy: 1) == 0, value.magnitude < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }
}
