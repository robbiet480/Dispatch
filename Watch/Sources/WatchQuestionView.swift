import DispatchKit
import SwiftData
import SwiftUI

/// Minimal per-type input for filing one question from the wrist (plan 19
/// v1): yes/no buttons, choice list, number via stepper (digital-crown
/// friendly), text via the system input (dictation/scribble come free with
/// TextField on watchOS). No drafts, no editing — file-and-done; the filing
/// path re-fetches the question by ID before saving (stale-UI rule).
struct WatchQuestionView: View {
    let question: Question

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var state: FilingState = .idle
    @State private var numberValue: Double = 0
    @State private var text: String = ""
    /// Time-question input (plan 28): minutes-since-midnight scrolled by the
    /// digital crown in 5-minute detents, plus a yesterday toggle. Seeded to
    /// "now" on appear.
    @State private var timeMinutes: Double = 0
    @State private var timeYesterday = false
    @State private var filingTask: Task<Void, Never>?

    enum FilingState: Equatable {
        case idle, filing, filed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(question.prompt)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                switch state {
                case .filing:
                    HStack {
                        ProgressView()
                        Text("Filing…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Filing report")
                case .filed:
                    Label("Filed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("watch-question-filed")
                case .idle:
                    inputControls
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Answer")
        .onAppear {
            if question.type == .number {
                let config = NumberInputStyle.resolvedConfig(
                    for: question.inputStyle,
                    min: question.inputMin, max: question.inputMax,
                    step: question.inputStep
                )
                numberValue = config.min
            } else if question.type == .time {
                timeMinutes = Double(TimeAnswer.now().minutesSinceMidnight)
            }
        }
        .onDisappear { filingTask?.cancel() }
    }

    @ViewBuilder
    private var inputControls: some View {
        switch question.type {
        case .yesNo:
            HStack(spacing: 8) {
                choiceButton(question.choices.first ?? "Yes", tint: .green)
                choiceButton(question.choices.count > 1 ? question.choices[1] : "No", tint: .red)
            }
        case .multipleChoice:
            ForEach(question.choices, id: \.self) { choice in
                choiceButton(choice, tint: .accentColor)
            }
        case .number:
            numberControls
        case .time:
            timeControls
        case .tokens, .people, .note, .location:
            textControls
        }
    }

    private func choiceButton(_ title: String, tint: Color) -> some View {
        Button(title) {
            file(.options([title]))
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .accessibilityLabel("\(title): \(question.prompt)")
    }

    private var numberControls: some View {
        let config = NumberInputStyle.resolvedConfig(
            for: question.inputStyle,
            min: question.inputMin, max: question.inputMax, step: question.inputStep
        )
        return VStack(spacing: 8) {
            // Stepper is the watch-minimal number input (plan 19 v1); it is
            // crown/tap friendly and honors the question's configured bounds.
            Stepper(value: $numberValue, in: config.min...config.max, step: config.step) {
                Text(formattedNumber)
                    .font(.title3)
                    .monospacedDigit()
            }
            .accessibilityLabel("Value for \(question.prompt)")
            .accessibilityValue(formattedNumber)
            Button("File") {
                file(.number(formattedNumber))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("watch-file-number")
        }
    }

    /// Minimal crown-scrollable time input (plan 28 watch). A large readout
    /// scrubbed by the digital crown over 0…1439 minutes in 5-minute detents,
    /// a compact Yesterday toggle, and File. Files `.time` through the shared
    /// AnswerValue path — the phone reconciles it via v2 sync with no extra work.
    private var timeControls: some View {
        VStack(spacing: 8) {
            Text(currentTimeAnswer.displayText())
                .font(.title3)
                .monospacedDigit()
                .focusable()
                .digitalCrownRotation(
                    $timeMinutes, from: 0, through: 1439, by: 5,
                    sensitivity: .medium, isContinuous: false
                )
                .accessibilityLabel("Time for \(question.prompt)")
                .accessibilityValue(currentTimeAnswer.displayText())
                .accessibilityIdentifier("watch-time-readout")
            Toggle("Yesterday", isOn: $timeYesterday)
                .accessibilityIdentifier("watch-time-yesterday")
            Button("File") {
                file(.time(currentTimeAnswer))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("watch-file-time")
        }
    }

    private var currentTimeAnswer: TimeAnswer {
        TimeAnswer(minutesSinceMidnight: Int(timeMinutes.rounded()),
                   dayOffset: timeYesterday ? -1 : 0)
    }

    private var textControls: some View {
        VStack(spacing: 8) {
            // TextField on watchOS presents the system input UI — dictation,
            // scribble, and QuickType come built in.
            TextField(question.placeholderString ?? "Answer", text: $text)
                .accessibilityLabel("Answer for \(question.prompt)")
            Button("File") {
                file(textValue)
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("watch-file-text")
        }
    }

    private var textValue: AnswerValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch question.type {
        case .note: return .note(trimmed)
        case .location: return .location(text: trimmed)
        default: return .tokens([trimmed])
        }
    }

    private var formattedNumber: String {
        numberValue.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(numberValue))
            : String(numberValue)
    }

    private func file(_ value: AnswerValue) {
        guard state == .idle else { return }
        state = .filing
        let context = modelContext
        let questionID = question.uniqueIdentifier
        let type = question.type
        filingTask = Task {
            do {
                let report = try await WatchReportFiler.file(
                    questionID: questionID, expectedType: type, value: value, in: context
                )
                guard report != nil else {
                    state = .idle
                    return
                }
                state = .filed
                WatchWidgetRefresher.reload()
                try? await Task.sleep(for: .seconds(1.5))
                dismiss()
            } catch {
                watchFilingLog.error("filing failed: \(error, privacy: .public)")
                state = .idle
            }
        }
    }
}
