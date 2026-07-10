import Foundation
import SwiftData

/// Kit-side core of Settings → Data → "Delete All Data…" (App Store
/// review-readiness blocker #2): erases every row of every model in one
/// background-context pass with a SINGLE save, so CloudKit mirroring (when
/// sync is on) propagates the deletions to the user's private database as
/// ordinary record deletes.
///
/// CloudKit decision: mirroring-propagated deletion is the ONLY cloud-erase
/// path. No direct CKContainer/zone purge is attempted — SwiftData owns the
/// mirrored schema, a manual zone delete would race the mirroring delegate,
/// and row deletion through the store is the supported way to clear the
/// server copy. Consequence (surfaced honestly in the confirmation UI):
/// deletions reach iCloud only while sync can run; with sync off or no
/// account they clear whenever sync is next enabled.
public enum DeleteAllData {
    /// Rows removed per model, for logging at the call site.
    public struct Counts: Equatable, Sendable {
        public var reports = 0
        public var responses = 0
        public var questions = 0
        public var promptGroups = 0
        public var tokens = 0
        public var people = 0

        public var total: Int {
            reports + responses + questions + promptGroups + tokens + people
        }
    }

    /// Deletes ALL rows of every model in `context` and saves ONCE.
    ///
    /// Responses are deleted explicitly (not left to the Report cascade) so
    /// the pass never depends on when SwiftData materializes cascade deletes,
    /// and orphaned rows (report already nil) are caught too. Order is
    /// responses → reports → questions → prompt groups → vocabulary.
    @discardableResult
    public static func deleteAllModels(in context: ModelContext) throws -> Counts {
        var counts = Counts()
        counts.responses = try deleteAll(Response.self, in: context)
        counts.reports = try deleteAll(Report.self, in: context)
        counts.questions = try deleteAll(Question.self, in: context)
        counts.promptGroups = try deleteAll(PromptGroup.self, in: context)
        counts.tokens = try deleteAll(TokenEntity.self, in: context)
        counts.people = try deleteAll(PersonEntity.self, in: context)
        try context.save()
        return counts
    }

    /// Row-by-row (fetch + delete), NOT a batch delete: batch deletes bypass
    /// the persistent-history machinery CloudKit mirroring relies on, so the
    /// server copy would never learn about them.
    private static func deleteAll<T: PersistentModel>(
        _ type: T.Type, in context: ModelContext
    ) throws -> Int {
        let rows = try context.fetch(FetchDescriptor<T>())
        for row in rows {
            context.delete(row)
        }
        return rows.count
    }

    // MARK: - Runtime defaults

    /// App-suite defaults keys cleared by delete-all — each one is state
    /// KEYED TO THE DELETED DATA. Everything not listed here survives on
    /// purpose; see `retainedDefaultsKeysRationale` for the per-key calls.
    public static let clearedDefaultsKeys: [String] = [
        // NotificationPrefs.lastActedAt — timestamp of the user's last
        // interaction with a (now deleted) prompt; a stale value would
        // suppress nag chains for the fresh schedule.
        "lastActedAt",
        // VisualizationFilterStore — hidden-question IDs and persisted filter
        // criteria both reference question IDs that no longer exist.
        "visualization.hiddenQuestionIDs",
        "visualization.filterCriteria",
        // WorkoutEndObserver.lastSeenKey — high-water mark for workout-end
        // prompt groups, all of which were just deleted.
        "workoutEnd.lastSeenEndDate",
        // VisitObserver.lastHandledKey — same, for visit-arrival groups.
        "visitArrival.lastHandledArrivalDate",
    ]

    /// App Group-suite keys cleared by delete-all (widget ↔ app contract
    /// state describing the deleted data).
    public static let clearedAppGroupDefaultsKeys: [String] = [
        // WidgetQuickAnswerMarker — pending/filed markers about reports that
        // no longer exist; draining a stale marker would touch lastActedAt.
        WidgetQuickAnswerMarker.pendingActedAtKey,
        WidgetQuickAnswerMarker.filedAtKey,
        // WidgetRefresher.nextPromptDateKey — next fire date of the deleted
        // schedule; the post-delete replan republishes a fresh one.
        "widget.nextPromptDate",
        // WebhookQueue (plan 24) — queued delivery IDs reference reports
        // that no longer exist. The webhook URL/enabled config (device-
        // local) survives as a user setting; the SECRET is a credential in
        // the Keychain and is wiped by the app-side delete-all flow
        // (WebhookManager.clearSecretForDataWipe).
        WebhookQueue.queueKey,
    ]

    /// Documentation of the deliberate KEEPS (asserted by the kit test so
    /// nobody "cleans up" the clear-list into wiping these):
    /// - "onboarding.completed" — the user still onboarded; delete-all must
    ///   not re-run onboarding.
    /// - "migration.defaultQuestionUUIDs" / "scheduleStampFormatVersion" —
    ///   one-time migration markers describing THIS INSTALL's format history,
    ///   not the data; re-running either against reseeded rows is wrong.
    /// - "focusFilterState" — mirrors the device's live Focus, delivered by
    ///   the system; it is device state, not report data, and clearing it
    ///   would un-mute prompts while a Focus is genuinely active.
    /// - Preference keys (alertsPerDay, distribution, nag*, digestEnabled,
    ///   scheduledTimes, theme/units/sensor toggles, backup.enabled,
    ///   iCloudSyncEnabled, privacy.appLockEnabled, awake.isAwake) — user
    ///   settings, not user data.
    /// - "backup.lastBackupDate" — owned by BackupManager; cleared only via
    ///   its deleteAllBackups() when the user opts into deleting backups.
    public static let retainedDefaultsKeys: [String] = [
        "onboarding.completed",
        "migration.defaultQuestionUUIDs",
        "scheduleStampFormatVersion",
        "focusFilterState",
        "backup.lastBackupDate",
    ]

    /// Clears the app-suite runtime keys listed above.
    public static func clearRuntimeDefaults(_ defaults: UserDefaults) {
        for key in clearedDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
    }

    /// Clears the App Group-suite keys listed above.
    public static func clearAppGroupDefaults(_ defaults: UserDefaults) {
        for key in clearedAppGroupDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
