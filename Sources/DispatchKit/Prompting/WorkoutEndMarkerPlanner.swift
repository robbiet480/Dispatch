import Foundation

/// Outcome of deciding what to do with the batch of workouts ending after the
/// persisted last-seen marker on a workout-end observer fire.
public struct WorkoutEndMarkerPlan: Equatable {
    /// Whether to post workout-end group prompts now.
    public let shouldPrompt: Bool
    /// The value the last-seen marker should become. Never moves backward.
    public let newMarker: Date

    public init(shouldPrompt: Bool, newMarker: Date) {
        self.shouldPrompt = shouldPrompt
        self.newMarker = newMarker
    }
}

/// Pure, deterministic decision for the workout-end observer: given the current
/// last-seen marker, the newest workout end date past it (if any), and whether
/// the user is awake, decide whether to prompt now and what the marker becomes.
///
/// The critical rule is the asleep case: a workout that ends while asleep must
/// NOT advance the marker, otherwise it is permanently swallowed (the next
/// fetch only looks past the advanced marker and never sees it again). Leaving
/// the marker put keeps those workouts eligible so they prompt on the next
/// fire (i.e. after wake). Re-considering is safe because the content-addressed
/// notification identifiers dedupe a workout that prompts on a later fire.
public enum WorkoutEndMarkerPlanner {
    /// - Parameters:
    ///   - currentMarker: The persisted last-seen workout end date.
    ///   - newestEndDate: The newest end date among workouts past the marker,
    ///     or nil when there are none.
    ///   - isAwake: Whether the user is currently awake.
    public static func plan(currentMarker: Date, newestEndDate: Date?, isAwake: Bool) -> WorkoutEndMarkerPlan {
        guard let newestEndDate else {
            // No workouts past the marker: nothing to do, marker unchanged.
            return WorkoutEndMarkerPlan(shouldPrompt: false, newMarker: currentMarker)
        }
        guard isAwake else {
            // Asleep: do NOT prompt and do NOT advance the marker, so the
            // skipped workouts stay eligible on the next fire (the fix).
            return WorkoutEndMarkerPlan(shouldPrompt: false, newMarker: currentMarker)
        }
        // Awake: prompt and advance the marker, but never move it backward.
        let advanced = max(currentMarker, newestEndDate)
        return WorkoutEndMarkerPlan(shouldPrompt: true, newMarker: advanced)
    }
}
