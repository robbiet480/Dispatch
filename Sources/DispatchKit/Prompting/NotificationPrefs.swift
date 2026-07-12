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

    /// Weekly digest notification (Sunday 19:00 local, `digest-weekly`).
    /// Default OFF — the digest screen is always reachable from Settings;
    /// this only controls the reminder.
    ///
    /// Superseded by `digestSchedules` (plan 40): the key is abandoned in
    /// place, read exactly once by `migrateDigestSchedulesIfNeeded()` and
    /// never again.
    public var digestEnabled: Bool {
        get {
            defaults.bool(forKey: "digestEnabled") // default false
        }
        set {
            defaults.set(newValue, forKey: "digestEnabled")
        }
    }

    /// The app's own random/global check-in schedule — the FREQUENCY
    /// (alerts-per-day) + DISTRIBUTION prompts that fire "What are you up to
    /// right now?" a few times a day, separate from Prompt Groups (plan 51).
    /// When OFF the scheduler plans ZERO random global prompts, so a user can
    /// rely on Prompt Groups only; explicit SCHEDULED times are unaffected.
    ///
    /// Default TRUE, and migration-safe: `UserDefaults.bool(forKey:)` returns
    /// `false` for an ABSENT key, which would SILENTLY disable the randoms of
    /// every existing user (who has never written this key). So absence is
    /// detected explicitly via `object(forKey:) == nil` and mapped to `true` —
    /// only an explicit stored `false` (the user flipping the toggle off)
    /// disables the randoms.
    public var randomCheckInsEnabled: Bool {
        get {
            guard defaults.object(forKey: "randomCheckInsEnabled") != nil else {
                return true // absent ⇒ existing user / fresh install: keep randoms on
            }
            return defaults.bool(forKey: "randomCheckInsEnabled")
        }
        set {
            defaults.set(newValue, forKey: "randomCheckInsEnabled")
        }
    }

    /// Automatic AWAKE/ASLEEP state from Sleep Focus + HealthKit (plan 39).
    /// Default OFF — a user who never opens the toggle sees zero behavior
    /// change; the manual pill keeps its exact semantics either way.
    public var autoSleepEnabled: Bool {
        get {
            defaults.bool(forKey: "autoSleepEnabled") // default false
        }
        set {
            defaults.set(newValue, forKey: "autoSleepEnabled")
        }
    }

    /// Configurable digest reminders (plan 40). Stored as JSON `Data` under
    /// `digestSchedules` — the `scheduledTimes` storage pattern verbatim,
    /// including silent decode/encode failure.
    public var digestSchedules: [DigestSchedule] {
        get {
            guard let jsonData = defaults.data(forKey: "digestSchedules") else {
                return []
            }
            return (try? JSONDecoder().decode([DigestSchedule].self, from: jsonData)) ?? []
        }
        set {
            if let jsonData = try? JSONEncoder().encode(newValue) {
                defaults.set(jsonData, forKey: "digestSchedules")
            }
        }
    }

    /// One-time plan-40 migration: `digestEnabled == true` becomes the exact
    /// schedule plan 14 hardcoded (weekly, Sunday, 19:00); false becomes an
    /// empty list. Writing the array (even empty) marks migration done — the
    /// key's presence is the marker. `digestEnabled` is never read again.
    public func migrateDigestSchedulesIfNeeded() {
        guard defaults.data(forKey: "digestSchedules") == nil else { return }
        digestSchedules = digestEnabled
            ? [DigestSchedule(id: UUID(), cadence: .weekly(weekday: 1),
                              hour: 19, minute: 0, isEnabled: true)]
            : []
    }

    /// When the user last acted on a prompt (quick answer, snooze,
    /// tap-through, or in-app report save). Replans use this to avoid
    /// resurrecting nag chains for prompts the user already dealt with.
    /// Stored as a timeIntervalSince1970 double; nil when never set.
    public var lastActedAt: Date? {
        get {
            let stored = defaults.double(forKey: "lastActedAt")
            guard stored > 0 else { return nil }
            return Date(timeIntervalSince1970: stored)
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: "lastActedAt")
            } else {
                defaults.removeObject(forKey: "lastActedAt")
            }
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
