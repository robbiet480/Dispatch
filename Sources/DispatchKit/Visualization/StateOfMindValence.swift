import Foundation

/// Pure mapping from an answered choice to Apple Health `HKStateOfMind` valence
/// [-1, +1]. Kept Foundation-only so it can be unit tested without HealthKit.
public enum StateOfMindValence {
    /// Maps an answered choice linearly onto valence [-1, +1]. Single
    /// choice ⇒ 0 (neutral); implicit Yes/No ⇒ Yes = +0.5, No = -0.5;
    /// otherwise the option's index across `choices` maps linearly
    /// (first = -1, last = +1). Returns nil for a nil/unanswered `answer`.
    public static func value(answer: String?, choices: [String], type: QuestionType) -> Double? {
        guard let answer else { return nil }

        let resolvedChoices = type == .yesNo && choices.isEmpty
            ? ["Yes", "No"]
            : choices

        if type == .yesNo {
            let yesLabel = resolvedChoices.first ?? "Yes"
            return answer == yesLabel ? 0.5 : -0.5
        }

        guard resolvedChoices.count > 1, let index = resolvedChoices.firstIndex(of: answer) else { return 0 }
        let fraction = Double(index) / Double(resolvedChoices.count - 1)
        return -1.0 + fraction * 2.0
    }
}
