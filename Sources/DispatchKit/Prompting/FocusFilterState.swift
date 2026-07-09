import Foundation

/// The active Dispatch Focus Filter's configuration (plan 15), written by
/// `DispatchFocusFilter.perform()` when a Focus with the filter configured
/// becomes active, and cleared when it deactivates. Persisted as JSON in the
/// App Group defaults suite so any process (app, intent-hosting background
/// launch, widgets) can read the same state.
///
/// Presence IS activity: a stored state means a Dispatch filter is active
/// right now; absence means no filter is active (Focus off, Focus without a
/// Dispatch filter configured, or filter never set up). A Focus with no
/// Dispatch filter never writes state, so it changes nothing — the full
/// schedule keeps running.
public struct FocusFilterState: Codable, Equatable, Sendable {
    /// The user-facing label captured into reports (e.g. "Work") — the
    /// filter's displayName parameter, not the system Focus name (Apple
    /// exposes no API for the actual Focus mode name).
    public var label: String
    /// PromptGroup uniqueIdentifiers allowed to fire while this filter is
    /// active. nil means "no group restriction" — every group keeps firing
    /// (a name-only filter: named Focus capture without muting). An empty
    /// array is distinct and means the user explicitly cleared the
    /// selection: every group is muted. Groups not listed are muted (their
    /// pending prompts removed on replan). Dangling IDs are harmless — they
    /// simply match no group.
    public var allowedGroupIDs: [String]?
    /// When true, the ungrouped/global schedule is paused while this filter
    /// is active; only the allowed groups fire.
    public var pauseGlobal: Bool
    /// When the filter activated — diagnostic/display only, never used in
    /// scheduling arithmetic.
    public var activatedAt: Date

    public init(label: String, allowedGroupIDs: [String]?, pauseGlobal: Bool, activatedAt: Date = Date()) {
        self.label = label
        self.allowedGroupIDs = allowedGroupIDs
        self.pauseGlobal = pauseGlobal
        self.activatedAt = activatedAt
    }

    /// Whether prompts for `groupID` may fire while this filter is active.
    /// A nil allowed set restricts nothing — every group fires.
    public func allows(groupID: String) -> Bool {
        allowedGroupIDs?.contains(groupID) ?? true
    }

    /// Whether the ungrouped/global schedule keeps firing under this filter.
    public var allowsGlobal: Bool {
        !pauseGlobal
    }

    // MARK: - Persistence (defaults suite, NotificationPrefs style)

    /// JSON blob under this key in the App Group defaults suite.
    public static let defaultsKey = "focusFilterState"

    /// The stored state, or nil when no filter is active (absent key or
    /// undecodable blob — a corrupt blob fails open to "no filter", never to
    /// a muted schedule).
    public static func read(from defaults: UserDefaults) -> FocusFilterState? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(FocusFilterState.self, from: data)
    }

    /// Convenience for UI that only needs the active/inactive bit.
    public static func isActive(in defaults: UserDefaults) -> Bool {
        read(from: defaults) != nil
    }

    public func write(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }

    // MARK: - Plan filtering (pure)

    /// The scheduler's pre-filter (plan 15): given the enabled
    /// timer-scheduled groups and the (optional) active filter state,
    /// returns the groups that should be planned and whether the global
    /// schedule should be planned. Everything downstream — the single
    /// removal batch, nag chains, budget arithmetic — is untouched: muted
    /// groups simply never enter the plan, so their pending requests fall
    /// out in the existing remove-before-add replan.
    ///
    /// - nil state → (all groups, global on): no filter active.
    /// - active state → (allowed subset, `allowsGlobal`); a nil allowed
    ///   set restricts nothing (name-only filter, all groups planned)
    ///   while an EMPTY allowed set mutes every group; global follows
    ///   `pauseGlobal` in both cases.
    public static func filterPlan(
        groups: [PromptGroup], state: FocusFilterState?
    ) -> (groups: [PromptGroup], planGlobal: Bool) {
        guard let state else { return (groups, true) }
        return (groups.filter { state.allows(groupID: $0.uniqueIdentifier) }, state.allowsGlobal)
    }
}
