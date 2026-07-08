import Foundation

public final class NotificationPrefs: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var alertsPerDay: Int {
        get {
            let stored = defaults.integer(forKey: "alertsPerDay")
            if stored == 0 {
                return 4 // default
            }
            return max(1, min(12, stored))
        }
        set {
            defaults.set(max(1, min(12, newValue)), forKey: "alertsPerDay")
        }
    }

    public var distribution: PromptDistribution {
        get {
            if let rawValue = defaults.string(forKey: "distribution"),
               let dist = PromptDistribution(rawValue: rawValue) {
                return dist
            }
            return .semiRandom // default
        }
        set {
            defaults.set(newValue.rawValue, forKey: "distribution")
        }
    }

    public var scheduledTimes: [DateComponents] {
        get {
            guard let jsonData = defaults.data(forKey: "scheduledTimes") else {
                return []
            }
            do {
                return try JSONDecoder().decode([DateComponents].self, from: jsonData)
            } catch {
                return []
            }
        }
        set {
            do {
                let jsonData = try JSONEncoder().encode(newValue)
                defaults.set(jsonData, forKey: "scheduledTimes")
            } catch {
                // Silently ignore encoding errors
            }
        }
    }
}
