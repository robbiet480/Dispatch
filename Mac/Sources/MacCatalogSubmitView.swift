import DispatchKit
import SwiftData
import SwiftUI

/// Plan 47 (issue #58): the Mac catalog submission form — writes a
/// SubmittedQuestion for moderation via the shared `CatalogStore` (throttle +
/// duplicate pre-check live kit-side). Anonymous by default; reuses the shared
/// `NumberInputStyle.exposedConfigFields` config-form logic (plan 41).
struct MacCatalogSubmitView: View {
    let store: CatalogStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var prompt: String
    @State private var type: QuestionType
    @State private var choicesText: String
    @State private var creditName = ""
    @State private var inputStyle: NumberInputStyle
    @State private var inputMin: String
    @State private var inputMax: String
    @State private var inputStep: String
    @State private var defaultAnswer: String
    @State private var placeholder: String
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var submitted = false
    @State private var duplicate: CatalogQuestion?
    @State private var addedDuplicate = false

    init(store: CatalogStore, prompt: String = "", type: QuestionType = .yesNo, choices: [String] = [],
         inputStyle: NumberInputStyle = .textField, inputMin: String = "", inputMax: String = "",
         inputStep: String = "", defaultAnswer: String = "", placeholder: String = "") {
        self.store = store
        _prompt = State(initialValue: prompt)
        _type = State(initialValue: type)
        _choicesText = State(initialValue: choices.joined(separator: "\n"))
        _inputStyle = State(initialValue: inputStyle)
        _inputMin = State(initialValue: inputMin)
        _inputMax = State(initialValue: inputMax)
        _inputStep = State(initialValue: inputStep)
        _defaultAnswer = State(initialValue: defaultAnswer)
        _placeholder = State(initialValue: placeholder)
    }

    private var configFields: (min: Bool, max: Bool, step: Bool) { inputStyle.exposedConfigFields }

    private var choices: [String] {
        choicesText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            if submitted {
                confirmation
            } else {
                Form {
                    Section("Question") {
                        TextField("Prompt", text: $prompt, axis: .vertical)
                            .accessibilityIdentifier("mac-catalog-submit-prompt")
                        Picker("Type", selection: $type) {
                            ForEach(QuestionType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                    }
                    if type == .multipleChoice {
                        Section("Choices") {
                            TextField("One choice per line", text: $choicesText, axis: .vertical)
                                .lineLimit(3...10)
                        }
                    }
                    if type == .number {
                        Section("Input style") {
                            Picker("Input style", selection: $inputStyle) {
                                ForEach(NumberInputStyle.allCases, id: \.self) { style in
                                    Text(style.displayName).tag(style)
                                }
                            }
                            if configFields.min { TextField("Minimum", text: $inputMin) }
                            if configFields.max { TextField("Maximum", text: $inputMax) }
                            if configFields.step { TextField("Step", text: $inputStep) }
                        }
                        Section("Default answer") {
                            TextField("Value for empty responses", text: $defaultAnswer)
                        }
                    }
                    Section("Placeholder") {
                        TextField("Placeholder (optional)", text: $placeholder)
                    }
                    Section {
                        TextField("Credit name (optional)", text: $creditName)
                    } footer: {
                        Text("Submissions are anonymous unless you add a credit name. No account details are shared.")
                    }
                    if let duplicate {
                        Section {
                            Text("“\(duplicate.prompt)” is already in the catalog.")
                            if addedDuplicate {
                                Text("Added to your questions.").foregroundStyle(.secondary)
                            } else {
                                Button("Add to My Questions") {
                                    _ = store.addToMyQuestions(duplicate, context: context)
                                    addedDuplicate = true
                                }
                            }
                        } footer: {
                            Text("Reword your prompt to submit a different question.")
                        }
                    }
                    if let errorMessage {
                        Section { Text(errorMessage).foregroundStyle(.red) }
                    }
                    if let quotaMessage {
                        Section { Text(quotaMessage).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            HStack {
                Button(submitted ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !submitted {
                    Button("Send") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSubmitting || store.submissionsRemaining == 0)
                        .accessibilityIdentifier("mac-catalog-submit-send")
                }
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 520)
    }

    private var confirmation: some View {
        VStack(spacing: 12) {
            Text("Thanks!").font(.title2.weight(.semibold))
            Text("Your question was submitted for moderation. If it's approved, it will appear in the catalog for everyone.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("mac-catalog-submit-confirmation")
    }

    private var quotaMessage: String? {
        let remaining = store.submissionsRemaining
        if remaining == 0 {
            let reset = store.nextSubmissionAllowed?
                .formatted(date: .omitted, time: .shortened) ?? "tomorrow"
            return "Daily limit reached — try again after \(reset)."
        }
        if remaining <= 2 {
            return "\(remaining) submission\(remaining == 1 ? "" : "s") left today."
        }
        return nil
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        duplicate = nil
        addedDuplicate = false
        let prompt = prompt
        let typeRaw = type.rawValue
        let choices = type == .multipleChoice ? choices : []
        let credit = creditName
        let isNumber = type == .number
        let styleRaw = (isNumber && inputStyle != .textField) ? inputStyle.rawValue : nil
        var minValue = (isNumber && configFields.min) ? NumberInputStyle.parseConfigText(inputMin) : nil
        var maxValue = (isNumber && configFields.max) ? NumberInputStyle.parseConfigText(inputMax) : nil
        let stepValue = (isNumber && configFields.step)
            ? NumberInputStyle.parseConfigText(inputStep).flatMap { $0 > 0 ? $0 : nil } : nil
        if let low = minValue, let high = maxValue, low >= high {
            minValue = nil
            maxValue = nil
        }
        let defaultValue = isNumber ? defaultAnswer : ""
        let placeholderValue = placeholder
        Task {
            defer { isSubmitting = false }
            if case .unavailable(let reason) = await store.accountStatus() {
                errorMessage = reason
                return
            }
            do {
                try await store.submit(
                    prompt: prompt, typeRaw: typeRaw, choices: choices, creditName: credit,
                    inputStyle: styleRaw, defaultAnswer: defaultValue, placeholder: placeholderValue,
                    inputMin: minValue, inputMax: maxValue, inputStep: stepValue)
                submitted = true
            } catch let CatalogProviderError.duplicate(existing) {
                duplicate = existing
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
