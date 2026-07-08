import DispatchKit
import SwiftData
import SwiftUI

struct SurveyFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appDefaults) private var appDefaults
    @Query private var questions: [Question]
    @Environment(ThemeStore.self) private var themeStore
    @Environment(NotificationScheduler.self) private var notificationScheduler
    @State private var controller: SurveyController?
    /// Text fields register a synchronous flush closure here (see
    /// `LocalTextEditorField`/`PendingFlushRegistry`). Called immediately
    /// before any navigation/save so in-flight debounced keystrokes land in
    /// the survey model first — no typed text is lost to a swipe or DONE
    /// tap that beats the debounce timer.
    @State private var flushRegistry = PendingFlushRegistry()
    @State private var isShowingDiscardConfirmation = false
    let kind: ReportKind
    let trigger: ReportTrigger
    var overrideDate: Date? = nil
    /// Scopes the survey to this PromptGroup's questions (plan 12).
    var promptGroupID: String? = nil
    /// The HKWorkout UUID that fired a workout-end prompt; capture attaches
    /// that workout's details to the report (plan 12 amendment).
    var triggeringWorkoutID: String? = nil

    var body: some View {
        Group {
            if let controller {
                flow(controller)
            } else {
                ProgressView()
            }
        }
        .task {
            guard controller == nil else { return }
            // Group-scoped survey: resolve the group's ordered question IDs.
            // A dangling/deleted group degrades to the normal global survey.
            var groupQuestionIDs: [String]?
            if let promptGroupID {
                let id = promptGroupID
                var descriptor = FetchDescriptor<PromptGroup>(
                    predicate: #Predicate { $0.uniqueIdentifier == id })
                descriptor.fetchLimit = 1
                groupQuestionIDs = (try? modelContext.fetch(descriptor))?.first?.questionIDs
            }
            let newController = SurveyController(questions: questions, kind: kind, trigger: trigger,
                                                 overrideDate: overrideDate,
                                                 promptGroupID: groupQuestionIDs == nil ? nil : promptGroupID,
                                                 groupQuestionIDs: groupQuestionIDs,
                                                 triggeringWorkoutID: triggeringWorkoutID,
                                                 appDefaults: appDefaults)
            controller = newController
            await newController.startCapture(since: DispatchStore.lastReportDate(in: modelContext))
        }
    }

    @ViewBuilder
    private func flow(_ controller: SurveyController) -> some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(controller.survey.currentIndex + 1),
                         total: Double(max(controller.survey.pages.count, 1)))
                .padding()
                .accessibilityIdentifier("survey-progress")

            TabView(selection: Binding(
                get: { controller.survey.currentIndex },
                set: { newIndex in
                    flushRegistry.flushAll()
                    controller.survey.select(newIndex)
                })) {
                ForEach(Array(controller.survey.pages.enumerated()), id: \.element.id) { index, page in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if index == 0 {
                                if controller.isBackdated {
                                    backdatedNote
                                        .padding(.top)
                                } else {
                                    CaptureChecklistView(outcomes: controller.outcomes)
                                        .padding(.top)
                                }
                            }
                            QuestionPageView(page: page,
                                             value: controller.survey.answerValue(for: page.id),
                                             onAnswer: { controller.survey.answer($0, for: page.id) },
                                             flushRegistry: flushRegistry)
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack {
                Button("CANCEL") { isShowingDiscardConfirmation = true }
                    .accessibilityIdentifier("survey-cancel")
                Spacer()
                Text("\(controller.survey.currentIndex + 1) / \(max(controller.survey.pages.count, 1))")
                    .font(.footnote)
                Spacer()
                Button(controller.survey.isLastPage ? "DONE" : "NEXT") {
                    flushRegistry.flushAll()
                    if controller.survey.isLastPage {
                        if (try? controller.save(in: modelContext)) != nil {
                            // A filed report satisfies any past-due prompt:
                            // cancel their pending nag reminders.
                            notificationScheduler.reportFiled()
                        }
                        dismiss()
                    } else {
                        controller.survey.advance()
                    }
                }
                .accessibilityIdentifier("survey-next")
            }
            .font(.subheadline.weight(.semibold))
            .padding()
        }
        .background {
            // Paint under the keyboard too: without ignoring the keyboard
            // safe area the theme color stops at the keyboard's top edge,
            // leaving white behind its rounded corners and a white flash
            // while the keyboard re-attaches after the app regains focus.
            Color.themeBackground(themeStore.theme).opacity(0.9)
                .ignoresSafeArea()
        }
        .alert("Are you sure you want to discard this report?",
               isPresented: $isShowingDiscardConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) { dismiss() }
        }
    }

    private var backdatedNote: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath").frame(width: 24)
            Text("BACKDATED REPORT")
                .font(.subheadline.weight(.semibold))
                .kerning(1.2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .accessibilityIdentifier("backdated-note")
    }
}
