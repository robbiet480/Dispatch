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

    public var nagEnabled: Bool {
        get {
            defaults.bool(forKey: "nagEnabled") // default false
        }
        set {
            defaults.set(newValue, forKey: "nagEnabled")
        }
    }

    public var nagDelayMinutes: Int {
        get {
            let stored = defaults.integer(forKey: "nagDelayMinutes")
            if stored == 0 {
                return 10 // default
            }
            return max(1, min(120, stored))
        }
        set {
            defaults.set(max(1, min(120, newValue)), forKey: "nagDelayMinutes")
        }
    }

    public var nagIntervalMinutes: Int {
        get {
            let stored = defaults.integer(forKey: "nagIntervalMinutes")
            if stored == 0 {
                return 5 // default
            }
            return max(1, min(60, stored))
        }
        set {
            defaults.set(max(1, min(60, newValue)), forKey: "nagIntervalMinutes")
        }
    }

    public var nagMaxCount: Int {
        get {
            let stored = defaults.integer(forKey: "nagMaxCount")
            if stored == 0 {
                return 3 // default
            }
            return max(1, min(10, stored))
        }
        set {
            defaults.set(max(1, min(10, newValue)), forKey: "nagMaxCount")
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
