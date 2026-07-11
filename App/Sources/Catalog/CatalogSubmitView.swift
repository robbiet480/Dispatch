import DispatchKit
import SwiftData
import SwiftUI

/// "Submit a question" form: writes a SubmittedQuestion record to the public
/// database for moderation. Anonymous by default with an optional credit
/// name. Requires an iCloud account (and says so); the catalog itself is
/// browsable without one.
struct CatalogSubmitView: View {
    let store: CatalogStore

    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var prompt: String
    @State private var type: QuestionType
    @State private var choicesText: String
    @State private var creditName = ""
    /// Input configuration (plan 41), mirroring the question editor: style +
    /// default answer only apply to number questions, placeholder to any
    /// type. Config text is validated like the editor's — finite Doubles,
    /// min < max, step > 0; invalid entries are simply not sent.
    @State private var inputStyle: NumberInputStyle
    @State private var inputMin: String
    @State private var inputMax: String
    @State private var inputStep: String
    @State private var defaultAnswer: String
    @State private var placeholder: String
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var submitted = false
    /// Plan 42: the catalog entry this prompt duplicates, when the pre-check
    /// hit. Shown as an "add it instead" section; rewording clears it.
    @State private var duplicate: CatalogQuestion?
    @State private var addedDuplicate = false

    /// Blank by default (the catalog browser's "Submit a Question" entry);
    /// the question editor passes its current prompt/type/choices — and,
    /// since plan 41, its input configuration — to pre-fill.
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

    private var theme: Theme { themeStore.theme }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.themeBackground(theme)
                    .ignoresSafeArea()

                if submitted {
                    confirmation
                } else {
                    form
                }
            }
            .navigationTitle("Submit a Question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(submitted ? "Done" : "Cancel") { dismiss() }
                        .tint(.white)
                }
                if !submitted {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Send") { submit() }
                            .tint(.white)
                            .fontWeight(.semibold)
                            .disabled(isSubmitting || store.submissionsRemaining == 0)
                            .accessibilityIdentifier("catalog-submit-send")
                    }
                }
            }
        }
    }

    private var form: some View {
        List {
            Section {
                TextField("Prompt", text: $prompt, axis: .vertical)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("catalog-submit-prompt")
                    .listRowBackground(Color.white.opacity(0.12))

                Picker("Type", selection: $type) {
                    ForEach(QuestionType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .foregroundStyle(.white)
                .tint(.white.opacity(0.7))
                .listRowBackground(Color.white.opacity(0.12))
                .accessibilityIdentifier("catalog-submit-type")
            } header: {
                sectionHeader("QUESTION")
            }

            if type == .multipleChoice {
                Section {
                    TextField("One choice per line", text: $choicesText, axis: .vertical)
                        .lineLimit(3...10)
                        .foregroundStyle(.white)
                        .listRowBackground(Color.white.opacity(0.12))
                } header: {
                    sectionHeader("CHOICES")
                }
            }

            if type == .number {
                Section {
                    Picker("Input style", selection: $inputStyle) {
                        ForEach(NumberInputStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .foregroundStyle(.white)
                    .tint(.white.opacity(0.7))
                    .listRowBackground(Color.white.opacity(0.12))
                    .accessibilityIdentifier("catalog-submit-input-style")
                    if configFields.min {
                        TextField("Minimum", text: $inputMin)
                            .keyboardType(.decimalPad)
                            .foregroundStyle(.white)
                            .listRowBackground(Color.white.opacity(0.12))
                            .accessibilityIdentifier("catalog-submit-input-min")
                    }
                    if configFields.max {
                        TextField("Maximum", text: $inputMax)
                            .keyboardType(.decimalPad)
                            .foregroundStyle(.white)
                            .listRowBackground(Color.white.opacity(0.12))
                            .accessibilityIdentifier("catalog-submit-input-max")
                    }
                    if configFields.step {
                        TextField("Step", text: $inputStep)
                            .keyboardType(.decimalPad)
                            .foregroundStyle(.white)
                            .listRowBackground(Color.white.opacity(0.12))
                            .accessibilityIdentifier("catalog-submit-input-step")
                    }
                } header: {
                    sectionHeader("INPUT STYLE")
                } footer: {
                    if inputStyle != .textField {
                        Text("Blank fields use the style's defaults. Invalid values (minimum not below maximum, step of zero) are ignored.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                            .listRowBackground(Color.clear)
                    }
                }

                Section {
                    TextField("Value for empty responses", text: $defaultAnswer)
                        .keyboardType(.decimalPad)
                        .foregroundStyle(.white)
                        .listRowBackground(Color.white.opacity(0.12))
                        .accessibilityIdentifier("catalog-submit-default-answer")
                } header: {
                    sectionHeader("DEFAULT ANSWER")
                } footer: {
                    Text("Filled automatically when the question is left empty.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                TextField("Placeholder (optional)", text: $placeholder)
                    .foregroundStyle(.white)
                    .listRowBackground(Color.white.opacity(0.12))
                    .accessibilityIdentifier("catalog-submit-placeholder")
            } header: {
                sectionHeader("PLACEHOLDER")
            }

            Section {
                TextField("Credit name (optional)", text: $creditName)
                    .foregroundStyle(.white)
                    .listRowBackground(Color.white.opacity(0.12))
            } header: {
                sectionHeader("CREDIT")
            } footer: {
                Text("Submissions are anonymous unless you add a credit name. No account details are shared.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    // Footers don't inherit the rows' listRowBackground; without
                    // an explicit clear background this falls through to the
                    // system background — invisible in light mode, a black band
                    // in dark mode (user-reported, build 16).
                    .listRowBackground(Color.clear)
            }

            if let duplicate {
                Section {
                    Text("\u{201C}\(duplicate.prompt)\u{201D} is already in the catalog.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                        .listRowBackground(Color.white.opacity(0.12))
                        .accessibilityIdentifier("catalog-submit-duplicate")
                    if addedDuplicate {
                        Text("Added to your questions.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                            .listRowBackground(Color.white.opacity(0.12))
                            .accessibilityIdentifier("catalog-submit-duplicate-added")
                    } else {
                        Button("Add to My Questions") { addDuplicateToMyQuestions(duplicate) }
                            .foregroundStyle(.white)
                            .fontWeight(.semibold)
                            .listRowBackground(Color.white.opacity(0.12))
                            .accessibilityIdentifier("catalog-submit-duplicate-add")
                    }
                } footer: {
                    Text("Reword your prompt to submit a different question.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .listRowBackground(Color.clear)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red.opacity(0.9))
                        .listRowBackground(Color.white.opacity(0.12))
                        .accessibilityIdentifier("catalog-submit-error")
                }
            }

            // Plan 38: the per-device quota surfaces only when it bites
            // (≤2 remaining or exhausted) — friction shouldn't advertise
            // itself on a fresh install.
            if let quotaMessage {
                Section {
                    Text(quotaMessage)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("catalog-submit-quota")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Plan 27: readable column on iPad; no-op at iPhone widths.
        .readableColumn()
        .accessibilityIdentifier("catalog-submit-form")
    }

    private var confirmation: some View {
        VStack(spacing: 12) {
            Text("Thanks!")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text("Your question was submitted for moderation. If it's approved, it will appear in the catalog for everyone.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .padding()
        .accessibilityIdentifier("catalog-submit-confirmation")
    }

    private var choices: [String] {
        choicesText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The shared exposure table (`NumberInputStyle.exposedConfigFields`) —
    /// identical to the question editor's.
    private var configFields: (min: Bool, max: Bool, step: Bool) {
        inputStyle.exposedConfigFields
    }

    /// Quota footer text (plan 38): nil above 2 remaining, a countdown at
    /// 1–2, and the reset time once the rolling window is exhausted.
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

    /// Style/bounds/default gated to number questions, parsed with the
    /// editor's discipline: finite Doubles only, step > 0, an inverted
    /// min/max pair sends neither, `.textField` sends no style at all.
    /// "Add it instead": the existing add-from-catalog path — a LOCAL
    /// Question with a fresh UUID; adding twice is a no-op (plan 42).
    private func addDuplicateToMyQuestions(_ entry: CatalogQuestion) {
        _ = store.addToMyQuestions(entry, context: modelContext)
        addedDuplicate = true
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
                    inputStyle: styleRaw, defaultAnswer: defaultValue,
                    placeholder: placeholderValue,
                    inputMin: minValue, inputMax: maxValue, inputStep: stepValue
                )
                submitted = true
            } catch let CatalogProviderError.duplicate(existing) {
                duplicate = existing
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }
}
