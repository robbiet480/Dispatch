import Foundation
import Observation

/// Persisted visibility filter for Home visualization pages, keyed by
/// `Question.uniqueIdentifier`. Questions default to visible; only hidden ids are stored.
@Observable
public final class VisualizationFilterStore: @unchecked Sendable {
    private static let hiddenIDsKey = "visualization.hiddenQuestionIDs"

    private let defaults: UserDefaults
    private var hiddenIDs: Set<String>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.hiddenIDsKey) ?? []
        self.hiddenIDs = Set(stored)
    }

    public func isVisible(_ questionID: String) -> Bool {
        !hiddenIDs.contains(questionID)
    }

    public func setVisible(_ questionID: String, _ visible: Bool) {
        if visible {
            hiddenIDs.remove(questionID)
        } else {
            hiddenIDs.insert(questionID)
        }
        defaults.set(Array(hiddenIDs), forKey: Self.hiddenIDsKey)
    }
}
