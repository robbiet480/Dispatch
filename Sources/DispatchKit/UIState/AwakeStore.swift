import Foundation

/// The manual AWAKE/ASLEEP toggle. Flipping it returns the kind of report
/// to offer (sleep report when going to sleep, wake report when waking).
/// The state change is authoritative even if the user cancels that survey.
public final class AwakeStore: @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isAwake: Bool {
        get { defaults.object(forKey: "awake.isAwake") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "awake.isAwake") }
    }

    @discardableResult
    public func toggle() -> ReportKind {
        let kind: ReportKind = isAwake ? .sleep : .wake
        isAwake.toggle()
        return kind
    }
}
