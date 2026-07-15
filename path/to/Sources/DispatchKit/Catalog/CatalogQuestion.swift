# Update the `CatalogQuestion` to handle the new migration logic
import Foundation

class CatalogQuestion {
    // ...

    func migrateResponses() {
        // Determine the type of the question and the type of the responses
        let questionType = type
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
    }
}