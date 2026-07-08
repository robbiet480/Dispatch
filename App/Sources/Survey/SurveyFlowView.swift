import DispatchKit
import SwiftData
import SwiftUI

struct SurveyFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appDefaults) private var appDefaults
    @Query private var questions: [Question]
    @Environment(ThemeStore.self) private var themeStore
    @State private var controller: SurveyController?
    let kind: ReportKind
    let trigger: ReportTrigger
    var overrideDate: Date? = nil

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
            let newController = SurveyController(questions: questions, kind: kind, trigger: trigger,
                                                 overrideDate: overrideDate, appDefaults: appDefaults)
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
                set: { controller.survey.select($0) })) {
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
                                             onAnswer: { controller.survey.answer($0, for: page.id) })
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack {
                Button("CANCEL") { dismiss() }
                    .accessibilityIdentifier("survey-cancel")
                Spacer()
                Text("\(controller.survey.currentIndex + 1) / \(max(controller.survey.pages.count, 1))")
                    .font(.footnote)
                Spacer()
                Button(controller.survey.isLastPage ? "DONE" : "NEXT") {
                    if controller.survey.isLastPage {
                        try? controller.save(in: modelContext)
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
        .background(Color.themeBackground(themeStore.theme).opacity(0.9))
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
