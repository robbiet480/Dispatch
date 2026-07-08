import Foundation
import Observation

/// The manual AWAKE/ASLEEP toggle. Flipping it returns the kind of report
/// to offer (sleep report when going to sleep, wake report when waking).
/// The state change is authoritative even if the user cancels that survey.
@Observable
public final class AwakeStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private var _isAwake: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self._isAwake = defaults.object(forKey: "awake.isAwake") as? Bool ?? true
    }

    public var isAwake: Bool {
        get { _isAwake }
        set {
            _isAwake = newValue
            defaults.set(newValue, forKey: "awake.isAwake")
        }
    }

    @discardableResult
    public func toggle() -> ReportKind {
        let kind: ReportKind = isAwake ? .sleep : .wake
        isAwake.toggle()
        return kind
    }
}
