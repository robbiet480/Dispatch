import Foundation
import UserNotifications

/// The replan's authorization gate (kit-side so the decision is testable):
/// whether a given UNUserNotificationCenter authorization status permits
/// scheduling prompt requests at all.
///
/// Why this exists: `UNUserNotificationCenter.add` fails EVERY request with
/// "Source is not authorized" while permission is denied or not yet
/// determined — a full replan attempts seven-plus adds, and several replan
/// passes run at first launch (stamp-migration replan, remote-change
/// replans), so an unauthorized first launch logged dozens of error lines
/// for a completely expected state. The scheduler checks this gate up front
/// and skips the pass with one debug line instead; the grant path
/// (`requestPermissionIfNeeded`'s completion) replans as soon as permission
/// arrives, so nothing is lost by skipping early.
public enum ReplanAuthorizationGate {
    /// True when scheduling can proceed: full, provisional, or ephemeral
    /// (App Clip; unavailable on macOS, where the kit's tests run)
    /// authorization. `.denied` and `.notDetermined` — and any future
    /// unknown status, which would fail adds the same way — skip.
    public static func canSchedule(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional:
            return true
        #if !os(macOS)
        case .ephemeral:
            return true
        #endif
        default:
            return false
        }
    }
}
