import Foundation
import Observation

/// Persisted visibility filter for Home visualization pages, keyed by
/// `Question.uniqueIdentifier`, plus the content-filter criteria applied to
/// the reports feeding those pages. Questions default to visible; only hidden
/// ids are stored. Criteria default to none.
@Observable
public final class VisualizationFilterStore: @unchecked Sendable {
    /// Defaults key for the hidden-question-ID array. Public so the one-time
    /// default-question ID migration can rewrite persisted entries in place.
    public static let hiddenQuestionIDsDefaultsKey = "visualization.hiddenQuestionIDs"
    private static var hiddenIDsKey: String { hiddenQuestionIDsDefaultsKey }
    private static let criteriaKey = "visualization.filterCriteria"

    private let defaults: UserDefaults
    private var hiddenIDs: Set<String>
    /// Active content-filter criteria; reports must match ALL of them.
    public private(set) var criteria: [ReportFilter.FilterCriterion]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.hiddenIDsKey) ?? []
        self.hiddenIDs = Set(stored)
        if let data = defaults.data(forKey: Self.criteriaKey),
           let decoded = try? JSONDecoder().decode([ReportFilter.FilterCriterion].self, from: data) {
            self.criteria = decoded
        } else {
            self.criteria = []
        }
    }

    public func addCriterion(_ criterion: ReportFilter.FilterCriterion) {
        guard !criteria.contains(criterion) else { return }
        criteria.append(criterion)
        persistCriteria()
    }

    public func removeCriterion(_ criterion: ReportFilter.FilterCriterion) {
        criteria.removeAll { $0 == criterion }
        persistCriteria()
    }

    public func clearCriteria() {
        criteria = []
        persistCriteria()
    }

    private func persistCriteria() {
        if let data = try? JSONEncoder().encode(criteria) {
            defaults.set(data, forKey: Self.criteriaKey)
        }
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
