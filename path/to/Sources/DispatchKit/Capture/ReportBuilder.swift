# Update the `ReportBuilder` to handle the new migration logic
import Foundation

class ReportBuilder {
    // ...

    func buildReport(for question: Question, responses: [Response]) -> Report {
        // Determine the type of the question and the type of the responses
        let questionType = question.type
        let responseTypes = responses.map { $0.type }

        // Apply the necessary conversions
        switch questionType {
        case .tokens, .people:
            // Lossless conversion
            responses.forEach { $0.type = .text }
        case .text:
            // Non-lossless conversion
            responses.forEach { $0.type = $0.type }
        case .multipleChoice, .yesNo, .number, .time:
            // Non-lossless conversion
            responses.forEach { $0.type = $0.type }
        case .location:
            // Non-lossless conversion
            responses.forEach { $0.type = $0.type }
        }

        // Build the report
        let report = Report(question: question, responses: responses)
        return report
    }
}