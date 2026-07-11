import Foundation
import Observation

/// The manual AWAKE/ASLEEP toggle. Flipping it returns the kind of report
/// to offer (sleep report when going to sleep, wake report when waking).
/// The state change is authoritative even if the user cancels that survey.
/// Who last changed the awake state — the automation policy (plan 39)
/// needs to know whether the standing state is a user decision.
public enum AwakeChangeSource: String, Sendable {
    case manual, focusFilter, health
}

@Observable
public final class AwakeStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private var _isAwake: Bool

    /// Who last changed the state (plan 39). Backed by "awake.lastChangeSource".
    public private(set) var lastChangeSource: AwakeChangeSource?
    /// When the user last MANUALLY changed the state (plan 39) — the cooldown
    /// anchor that outranks automation. Backed by "awake.lastManualChangeAt".
    public private(set) var lastManualChangeAt: Date?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self._isAwake = defaults.object(forKey: "awake.isAwake") as? Bool ?? true
        if let raw = defaults.string(forKey: "awake.lastChangeSource") {
            self.lastChangeSource = AwakeChangeSource(rawValue: raw)
        }
        let stamp = defaults.double(forKey: "awake.lastManualChangeAt")
        if stamp > 0 {
            self.lastManualChangeAt = Date(timeIntervalSince1970: stamp)
        }
    }

    public var isAwake: Bool {
        get { _isAwake }
        set {
            _isAwake = newValue
            defaults.set(newValue, forKey: "awake.isAwake")
        }
    }

    /// Source-stamping state change (plan 39). MANUAL changes stamp the
    /// cooldown timestamp that outranks automation; automatic sources don't.
    /// The plain `isAwake` setter stays source-less for existing callers.
    public func setAwake(_ awake: Bool, source: AwakeChangeSource, now: Date = Date()) {
        isAwake = awake
        lastChangeSource = source
        defaults.set(source.rawValue, forKey: "awake.lastChangeSource")
        if source == .manual {
            lastManualChangeAt = now
            defaults.set(now.timeIntervalSince1970, forKey: "awake.lastManualChangeAt")
        }
    }

    @discardableResult
    public func toggle(now: Date = Date()) -> ReportKind {
        let kind: ReportKind = isAwake ? .sleep : .wake
        setAwake(!isAwake, source: .manual, now: now)
        return kind
    }
}
