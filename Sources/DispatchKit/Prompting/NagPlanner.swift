import Foundation

/// Pure planner for persistent (nag) reminder chains. For each prompt date,
/// produces follow-up fire dates at `promptDate + delay + (n-1)*interval`
/// for n = 1...effectiveCount.
///
/// iOS caps pending notification requests at 64 per app, so the per-prompt
/// nag count is clamped against a `budget` (the slots available to prompts
/// plus nags): `effectiveCount = min(maxCount, (budget - promptCount) /
/// promptCount)`, floored at 0. Deterministic — same inputs, same output.
public enum NagPlanner {
    public static func plan(
        promptDates: [Date],
        delayMinutes: Int,
        intervalMinutes: Int,
        maxCount: Int,
        budget: Int
    ) -> [(parent: Date, fires: [Date])] {
        guard !promptDates.isEmpty else { return [] }

        let promptCount = promptDates.count
        let budgetPerPrompt = (budget - promptCount) / max(1, promptCount)
        let effectiveCount = max(0, min(maxCount, budgetPerPrompt))

        let delay = TimeInterval(delayMinutes * 60)
        let interval = TimeInterval(intervalMinutes * 60)

        return promptDates.map { parent in
            let fires = (0..<effectiveCount).map { n in
                parent.addingTimeInterval(delay + TimeInterval(n) * interval)
            }
            return (parent: parent, fires: fires)
        }
    }
}
