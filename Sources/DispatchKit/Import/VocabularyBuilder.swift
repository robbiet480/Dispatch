import Foundation
import SwiftData

public enum VocabularyBuilder {
    /// Rebuilds token/person vocabularies from all stored responses.
    /// People-type questions feed PersonEntity; token-type feed TokenEntity.
    public static func rebuild(in context: ModelContext) throws {
        let questions = try context.fetch(FetchDescriptor<Question>())
        let typeByPrompt = Dictionary(questions.map { ($0.prompt, $0.type) },
                                      uniquingKeysWith: { first, _ in first })
        let responses = try context.fetch(FetchDescriptor<Response>())

        struct Tally { var uses = 0; var prompts = Set<String>() }
        var tokenTally: [String: Tally] = [:]
        var personTally: [String: Tally] = [:]

        for response in responses {
            guard let values = response.tokens, !values.isEmpty else { continue }
            let isPeople = typeByPrompt[response.questionPrompt] == .people
            for value in values {
                var tally = (isPeople ? personTally : tokenTally)[value.text] ?? Tally()
                tally.uses += 1
                tally.prompts.insert(response.questionPrompt)
                if isPeople { personTally[value.text] = tally } else { tokenTally[value.text] = tally }
            }
        }

        try context.delete(model: TokenEntity.self)
        try context.delete(model: PersonEntity.self)
        for (text, tally) in tokenTally {
            let entity = TokenEntity()
            entity.text = text
            entity.usageCount = tally.uses
            entity.questionCount = tally.prompts.count
            context.insert(entity)
        }
        for (text, tally) in personTally {
            let entity = PersonEntity()
            entity.text = text
            entity.usageCount = tally.uses
            entity.questionCount = tally.prompts.count
            context.insert(entity)
        }
        try context.save()
    }
}
