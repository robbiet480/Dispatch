import DispatchKit
import SwiftData
import SwiftUI

struct SurveyFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var questions: [Question]
    @State private var controller: SurveyController?
    let kind: ReportKind
    let trigger: ReportTrigger

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
            let newController = SurveyController(questions: questions, kind: kind, trigger: trigger)
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
                set: { _ in })) {
                ForEach(Array(controller.survey.pages.enumerated()), id: \.element.id) { index, page in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if index == 0 {
                                CaptureChecklistView(outcomes: controller.outcomes)
                                    .padding(.top)
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
        .background(Color(red: 0.98, green: 0.36, blue: 0.22).opacity(0.12))
    }
}
