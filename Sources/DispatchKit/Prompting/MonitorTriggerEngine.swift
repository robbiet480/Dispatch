import Foundation

/// A CLMonitor condition's reported state, mapped from `CLMonitor.Event`'s
/// state into a platform-clean enum so the decision logic runs under
/// `swift test` (the app never leaks CoreLocation types into the kit).
public enum MonitorConditionState: String, Sendable, Equatable {
    case satisfied
    case unsatisfied
    /// CLMonitor reports `.unknown` when a condition's state can't yet be
    /// determined; it is never a fire or a cancel.
    case unknown
}

/// What the observer should do in response to one condition-state event for
/// one group. `.schedule` carries the concrete fire date (event + delay); the
/// observer turns it into an `mprompt-` notification (nil trigger for
/// delay 0, `UNTimeIntervalNotificationTrigger` otherwise).
public enum MonitorTriggerOutcome: Equatable, Sendable {
    case schedule(fireDate: Date)
    case cancelPending
    case ignore
}

/// The pure delay/cancel decision for place (#56) and beacon (#60) triggers.
/// Shared by both because the only difference between the two features is the
/// CLMonitor *condition kind* — the arrival/departure + delay + cancel
/// semantics are identical. Kept platform-clean and TDD'd here so the timing
/// contract is proven without a device.
public enum MonitorTriggerEngine {
    /// - `direction`: `.arrival` fires on `.satisfied`, `.departure` fires on
    ///   `.unsatisfied`. The opposite state is the "contradiction".
    /// - On the fire state → `.schedule(eventDate + delayMinutes·60)`.
    /// - On the contradicting state → `.cancelPending` iff
    ///   `cancelOnContradiction`, else `.ignore` (a leave-before-delay that
    ///   the user opted to keep).
    /// - `.unknown` → `.ignore`.
    public static func outcome(
        direction: MonitorDirection,
        delayMinutes: Int,
        cancelOnContradiction: Bool,
        state: MonitorConditionState,
        eventDate: Date
    ) -> MonitorTriggerOutcome {
        let firesOn: MonitorConditionState = direction == .arrival ? .satisfied : .unsatisfied
        let cancelsOn: MonitorConditionState = direction == .arrival ? .unsatisfied : .satisfied
        if state == firesOn {
            // Multiply in `TimeInterval` (Double), NOT Int: a corrupt/hand-edited
            // import could carry a huge `delayMinutes`, and `x * 60` in Int would
            // overflow and trap here.
            let delay = TimeInterval(max(0, delayMinutes)) * 60
            return .schedule(fireDate: eventDate.addingTimeInterval(delay))
        }
        if state == cancelsOn {
            return cancelOnContradiction ? .cancelPending : .ignore
        }
        return .ignore
    }
}
