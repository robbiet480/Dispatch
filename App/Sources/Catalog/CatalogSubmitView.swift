import DispatchKit
import SwiftUI

/// "Submit a question" form: writes a SubmittedQuestion record to the public
/// database for moderation. Anonymous by default with an optional credit
/// name. Requires an iCloud account (and says so); the catalog itself is
/// browsable without one.
struct CatalogSubmitView: View {
    let store: CatalogStore

    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var type: QuestionType = .yesNo
    @State private var choicesText = ""
    @State private var creditName = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var submitted = false

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
                            .disabled(isSubmitting)
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
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        let prompt = prompt
        let typeRaw = type.rawValue
        let choices = type == .multipleChoice ? choices : []
        let credit = creditName
        Task {
            defer { isSubmitting = false }
            if case .unavailable(let reason) = await store.accountStatus() {
                errorMessage = reason
                return
            }
            do {
                try await store.submit(
                    prompt: prompt, typeRaw: typeRaw, choices: choices, creditName: credit
                )
                submitted = true
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
