import Foundation
import SwiftData

public struct QuestionRef: Sendable, Equatable {
    public let uniqueIdentifier: String
    public let prompt: String
    public let type: QuestionType
    public init(uniqueIdentifier: String, prompt: String, type: QuestionType) {
        self.uniqueIdentifier = uniqueIdentifier
        self.prompt = prompt
        self.type = type
    }
}

public enum AnswerValue: Equatable, Sendable {
    case tokens([String])
    case options([String])
    case number(String)
    case note(String)
    case location(text: String)
    case skipped
}

public struct AnswerDraft: Sendable {
    public let question: QuestionRef
    public let value: AnswerValue
    public init(question: QuestionRef, value: AnswerValue) {
        self.question = question
        self.value = value
    }
}

public enum ReportBuilder {
    /// Assembles and saves a Report from capture outcomes and survey answers.
    /// Unavailable/disabled sensors are simply absent from the report.
    /// Every shown question records a Response — payload-less when skipped,
    /// matching the original app's export semantics.
    @discardableResult
    public static func save(
        kind: ReportKind,
        trigger: ReportTrigger,
        date: Date,
        timeZone: TimeZone,
        outcomes: [SensorKind: SensorOutcome],
        answers: [AnswerDraft],
        in context: ModelContext
    ) throws -> Report {
        let report = Report()
        report.date = date
        report.timeZoneIdentifier = timeZone.identifier
        report.kind = kind
        report.trigger = trigger

        var health: [HealthReading] = []
        for outcome in outcomes.values {
            guard case .captured(let payload) = outcome else { continue }
            switch payload {
            case .location(let snapshot): report.location = snapshot
            case .weather(let observation): report.weather = observation
            case .altitude(let meters): report.altitudeMeters = meters
            case .photos(_, let records): report.photos = records
            case .audio(let sample): report.audio = sample
            case .battery(let level): report.battery = level
            case .connection(let raw): report.connection = raw
            case .focus(let state): report.focus = state
            case .health(let readings): health.append(contentsOf: readings)
            }
        }
        report.health = health.sorted { $0.type < $1.type }
        context.insert(report)

        for draft in answers {
            let response = Response()
            response.questionPrompt = draft.question.prompt
            response.questionIdentifier = draft.question.uniqueIdentifier
            switch draft.value {
            case .tokens(let texts):
                response.tokens = texts.map { TokenValue(text: $0) }
            case .options(let options):
                response.answeredOptions = options
            case .number(let number):
                response.numericResponse = number
            case .note(let text):
                response.textResponses = [TokenValue(text: text)]
            case .location(let text):
                var answer = LocationAnswer()
                answer.text = text
                answer.location = report.location
                response.locationResponse = answer
            case .skipped:
                break
            }
            response.report = report
            context.insert(response)
        }

        try context.save()
        try VocabularyBuilder.rebuild(in: context)
        return report
    }
}

public extension DispatchStore {
    static func lastReportDate(in context: ModelContext) -> Date? {
        var descriptor = FetchDescriptor<Report>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.date
    }
}
