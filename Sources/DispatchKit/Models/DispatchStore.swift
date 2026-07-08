import Foundation
import SwiftData

public enum DispatchStore {
    public static let allModels: [any PersistentModel.Type] = [
        Question.self, Report.self, Response.self, TokenEntity.self, PersonEntity.self,
        PromptGroup.self,
    ]

    public static func inMemoryContainer() throws -> ModelContainer {
        let schema = Schema(allModels)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
