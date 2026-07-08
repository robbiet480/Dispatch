import DispatchKit
import SwiftUI

struct QuestionPageView: View {
    let page: SurveyPage
    let value: AnswerValue
    let onAnswer: (AnswerValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(page.question.prompt.uppercased())
                .font(.subheadline.weight(.semibold))
                .kerning(1.2)
                .padding(.horizontal)
                .padding(.bottom, 8)
            Divider()
            answerBody
            Spacer()
        }
    }

    @ViewBuilder
    private var answerBody: some View {
        switch page.question.type {
        case .yesNo, .multipleChoice:
            ChoiceListView(choices: page.choices,
                           multiSelect: page.question.type == .multipleChoice,
                           selected: selectedOptions,
                           onSelect: { onAnswer(.options($0)) })
        case .tokens, .people:
            TokenEntryView(placeholder: page.placeholder ?? "Add…",
                           tokens: currentTokens,
                           onChange: { onAnswer(.tokens($0)) })
        case .number:
            TextField(page.placeholder ?? "0", text: numberBinding)
                .keyboardType(.decimalPad)
                .font(.title2)
                .padding()
                .accessibilityIdentifier("number-field")
        case .note:
            TextEditor(text: noteBinding)
                .frame(minHeight: 160)
                .padding(.horizontal)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("note-editor")
        case .location:
            TextField(page.placeholder ?? "Where are you?", text: locationBinding)
                .font(.title2)
                .padding()
                .accessibilityIdentifier("location-field")
        }
    }

    private var selectedOptions: [String] {
        if case .options(let options) = value { return options }
        return []
    }

    private var currentTokens: [String] {
        if case .tokens(let tokens) = value { return tokens }
        return []
    }

    private var numberBinding: Binding<String> {
        Binding(
            get: { if case .number(let number) = value { number } else { "" } },
            set: { onAnswer($0.isEmpty ? .skipped : .number($0)) })
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { if case .note(let note) = value { note } else { "" } },
            set: { onAnswer($0.isEmpty ? .skipped : .note($0)) })
    }

    private var locationBinding: Binding<String> {
        Binding(
            get: { if case .location(let text) = value { text } else { "" } },
            set: { onAnswer($0.isEmpty ? .skipped : .location(text: $0)) })
    }
}

struct ChoiceListView: View {
    let choices: [String]
    let multiSelect: Bool
    let selected: [String]
    let onSelect: ([String]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(choices, id: \.self) { choice in
                Button {
                    toggle(choice)
                } label: {
                    HStack {
                        Text(choice).font(.title3)
                        Spacer()
                        if selected.contains(choice) {
                            Image(systemName: "checkmark")
                        }
                    }
                    .padding()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(selected.isEmpty || selected.contains(choice) ? 1 : 0.5)
                Divider()
            }
        }
    }

    private func toggle(_ choice: String) {
        if multiSelect {
            var next = selected
            if let index = next.firstIndex(of: choice) { next.remove(at: index) } else { next.append(choice) }
            onSelect(next)
        } else {
            onSelect(selected == [choice] ? [] : [choice])
        }
    }
}

struct TokenEntryView: View {
    let placeholder: String
    let tokens: [String]
    let onChange: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !tokens.isEmpty {
                FlowingChips(tokens: tokens) { removed in
                    onChange(tokens.filter { $0 != removed })
                }
            }
            TextField(placeholder, text: $draft)
                .font(.title3)
                .onSubmit {
                    let trimmed = draft.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onChange(tokens + [trimmed])
                    draft = ""
                }
                .accessibilityIdentifier("token-field")
        }
        .padding()
    }
}

struct FlowingChips: View {
    let tokens: [String]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(tokens, id: \.self) { token in
                    Button {
                        onRemove(token)
                    } label: {
                        HStack(spacing: 4) {
                            Text(token)
                            Image(systemName: "xmark.circle.fill").imageScale(.small)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
