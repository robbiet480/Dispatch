import DispatchKit
import LocalAuthentication
import SwiftUI

/// Face ID / passcode app lock. `enabled` is persisted on the shared
/// appDefaults suite (same pattern as ThemeStore/AwakeStore) so it survives
/// relaunches and stays isolated under UI tests; `isLocked` is pure runtime
/// state that DispatchApp/ContentView drive based on scenePhase transitions.
///
/// Completely bypassed under `--ui-testing`/`--mock-sensors`: the app never
/// locks and enabling the toggle never touches LAContext, so UI tests never
/// hit a system biometrics prompt.
@Observable
public final class AppLockStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private var _enabled: Bool
    private var _spotlightWhileLockedEnabled: Bool
    public var isLocked: Bool = false

    /// Runtime-only: true while the app is covered for backgrounding but not
    /// (yet) locked — the privacy cover window is up hiding content from the
    /// app-switcher snapshot, but no authentication is required to return
    /// within the grace interval. Cleared by `evaluateReturnFromBackground`.
    public var isCovered: Bool = false

    /// Backgrounding this long or longer re-locks the app on return.
    public static let backgroundGraceInterval: TimeInterval = 60

    /// URLs opened while locked/covered wait here until a successful unlock
    /// (see LockedURLQueue in DispatchKit for the tested semantics). The
    /// Spotify OAuth callback lands via onOpenURL while the privacy cover is
    /// still up — processing it invisibly behind the cover while the unlock
    /// prompt may have been system-cancelled is exactly the "stranded on the
    /// lock screen" bug this queue fixes.
    private var urlQueue = LockedURLQueue()

    /// Observable token AppLockView watches to (re-)present the Face ID
    /// prompt: bumped whenever a URL arrives while locked, because the
    /// view's single onAppear auto-attempt can be system-cancelled during a
    /// URL-driven activation and nothing else would re-present it.
    public private(set) var unlockPromptRequestCount = 0

    public let isTestEnvironment: Bool

    public init(defaults: UserDefaults = .standard, isTestEnvironment: Bool? = nil) {
        self.defaults = defaults
        self._enabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        self._spotlightWhileLockedEnabled = defaults.bool(forKey: Self.spotlightWhileLockedDefaultsKey)
        self.isTestEnvironment = isTestEnvironment ?? {
            let arguments = ProcessInfo.processInfo.arguments
            return arguments.contains("--mock-sensors") || arguments.contains("--ui-testing")
        }()
    }

    /// Shared appDefaults key backing `enabled`. Exposed so `SpotlightIndexer` can check
    /// the lock policy without needing an `AppLockStore` instance.
    static let enabledDefaultsKey = "privacy.appLockEnabled"

    /// Static read of the app-lock-enabled flag, for call sites (like `SpotlightIndexer`)
    /// that need the policy but don't have (and shouldn't need) a full `AppLockStore`.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledDefaultsKey)
    }

    public var enabled: Bool {
        get { _enabled }
        set {
            _enabled = newValue
            defaults.set(newValue, forKey: Self.enabledDefaultsKey)
        }
    }

    /// Key backing the "Spotlight Search While Locked" opt-in. Defaults to false:
    /// enabling app lock stops Spotlight indexing unless the user explicitly
    /// accepts that search results can reveal report content without unlocking.
    static let spotlightWhileLockedDefaultsKey = "privacy.spotlightWhileLockedEnabled"

    /// Static read of the Spotlight-while-locked opt-in, for `SpotlightIndexer`
    /// (same pattern as `isEnabled(defaults:)`).
    public static func isSpotlightWhileLockedEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: spotlightWhileLockedDefaultsKey)
    }

    /// User opt-in: keep indexing report content into Spotlight even while app
    /// lock is enabled. Only consulted when `enabled` is true — with lock off,
    /// indexing always happens. Callers toggling this are responsible for the
    /// index side effects (rebuild on enable, wipe on disable) — see SettingsView.
    public var spotlightWhileLockedEnabled: Bool {
        get { _spotlightWhileLockedEnabled }
        set {
            _spotlightWhileLockedEnabled = newValue
            defaults.set(newValue, forKey: Self.spotlightWhileLockedDefaultsKey)
        }
    }

    /// Call at cold launch: locks immediately when enabled (never locks in test mode).
    public func lockAtLaunchIfNeeded() {
        guard !isTestEnvironment, enabled else { return }
        isLocked = true
    }

    /// Test-only hook for the `--enable-app-lock` launch argument: forces
    /// `enabled` and `isLocked` on at startup even though `isTestEnvironment`
    /// is true, so UI tests can exercise the lock screen. Unlocking still
    /// goes through `attemptUnlock()`, which succeeds instantly in test mode
    /// without touching LocalAuthentication.
    public func forceLockForUITesting() {
        guard isTestEnvironment else { return }
        enabled = true
        isLocked = true
    }

    /// Call synchronously the moment the scene leaves the foreground
    /// (`.inactive` or `.background`): marks the app as covered so the
    /// privacy cover window hides content before the app-switcher snapshot.
    ///
    /// Deliberately a no-op when already locked or covered: `.inactive` also
    /// fires for the Face ID system prompt itself (and notification-center
    /// pulls, share sheets, etc.), so re-covering mid-authentication must not
    /// disturb the in-progress unlock flow.
    public func coverForBackgroundingIfNeeded() {
        guard enabled, !isTestEnvironment, !isLocked, !isCovered else { return }
        isCovered = true
    }

    /// Call when the scene becomes active again after having backgrounded
    /// at `backgroundedAt`. Locks only if enabled and the grace interval
    /// elapsed. Always clears `isCovered` AFTER the lock decision, in the
    /// same main-actor turn, so there is never a gap where the app is
    /// neither covered nor locked but should be.
    public func evaluateReturnFromBackground(backgroundedAt: Date?) {
        defer { isCovered = false }
        guard !isTestEnvironment else { return }
        if AppLockPolicy.shouldLock(
            enabled: enabled,
            backgroundedAt: backgroundedAt,
            now: Date(),
            graceSeconds: Self.backgroundGraceInterval
        ) {
            isLocked = true
        }
    }

    /// Queues `url` when the app is locked or covered-for-backgrounding.
    /// Returns `true` when queued (the caller must not route it now — drain
    /// after unlock via `drainPendingURLs()`), `false` when the app is fully
    /// visible and the URL should be routed immediately. When already locked,
    /// also requests a fresh unlock prompt so returning via an OAuth callback
    /// always fires Face ID rather than stranding the user on the lock screen.
    public func deferURLIfNeeded(_ url: URL) -> Bool {
        guard urlQueue.deferIfNeeded(url, isLocked: isLocked, isCovered: isCovered) else {
            return false
        }
        if isLocked {
            unlockPromptRequestCount += 1
        }
        return true
    }

    /// Returns queued URLs in arrival order and empties the queue. Call only
    /// once the app is neither locked nor covered; a failed/cancelled unlock
    /// must NOT drain — the URLs stay queued for the next attempt.
    public func drainPendingURLs() -> [URL] {
        urlQueue.drain()
    }

    /// Attempts biometric/passcode authentication. In test mode, always
    /// succeeds instantly without calling into LocalAuthentication.
    @MainActor
    public func attemptUnlock() async -> Bool {
        if isTestEnvironment {
            isLocked = false
            return true
        }
        let context = LAContext()
        let reason = "Unlock Dispatch"
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if success {
                isLocked = false
            }
            return success
        } catch {
            return false
        }
    }

    /// Used by the settings toggle: enabling requires a successful auth
    /// first. Disabling never requires auth. In test mode, both set
    /// instantly with no LAContext call.
    ///
    /// Spotlight policy: while app lock is enabled, Dispatch does not index report
    /// content (unless the user opts into `spotlightWhileLockedEnabled`), so report
    /// text can't leak through system-wide Spotlight search when the device is
    /// locked/shared. Enabling wipes the existing index immediately
    /// (`SpotlightIndexer.deleteAll()`) since content indexed before lock was turned
    /// on must not remain searchable afterward.
    ///
    /// Disabling does *not* eagerly rebuild the index here: `AppLockStore` has no
    /// `ModelContext` access (it's a plain `UserDefaults`-backed store constructed
    /// before the SwiftData stack is wired to views), and reaching across into
    /// SwiftData from here would mean threading a context into a class that
    /// otherwise has none of that plumbing, for a one-off. Instead, re-indexing
    /// happens lazily: `SpotlightIndexer.index(report:)` already runs on every new
    /// report save, so the index self-heals going forward, and a full rebuild from
    /// all persisted reports can be triggered by `SpotlightIndexer.rebuildAll(reports:)`
    /// at next launch (call site TODO once a launch-time model fetch hook exists).
    /// This is the simpler-and-still-correct option: no report content is ever
    /// under-protected (worst case, older reports are briefly *not* searchable after
    /// disabling, which fails safe rather than fails open).
    @MainActor
    public func setEnabled(_ newValue: Bool) async {
        if !newValue {
            enabled = false
            return
        }
        if isTestEnvironment {
            enabled = true
            return
        }
        let context = LAContext()
        let reason = "Enable Face ID to lock Dispatch"
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if success {
                enabled = true
                // Wipe the index unless the user has already opted into
                // Spotlight-while-locked (in which case indexing stays allowed
                // and the existing index remains valid).
                if !spotlightWhileLockedEnabled {
                    SpotlightIndexer.deleteAll()
                }
            }
        } catch {
            // Leave disabled on failure/cancel.
        }
    }
}

/// Themed full-screen lock cover shown whenever `AppLockStore.isLocked` is true.
struct AppLockView: View {
    @Environment(AppLockStore.self) private var appLockStore
    @Environment(ThemeStore.self) private var themeStore
    @State private var isAuthenticating = false

    private var theme: Theme { themeStore.theme }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white)
                    // Decorative — the "Locked" text below carries the state.
                    .accessibilityHidden(true)

                Text(appName)
                    .font(.title.bold())
                    .foregroundStyle(.white)

                Text("Locked")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))

                Button {
                    unlock()
                } label: {
                    Text("Unlock")
                        .font(.headline)
                        .foregroundStyle(ThemeColor.color(theme))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Capsule().fill(.white))
                }
                .accessibilityIdentifier("app-lock-unlock-button")
                .padding(.horizontal, 40)
                .disabled(isAuthenticating)
            }
        }
        // .contain keeps this identifier on its own element rather than letting
        // SwiftUI merge the ZStack with its single interactive descendant (the
        // Unlock button), which otherwise makes "app-lock-view" resolve to a
        // Button carrying the button's own label/actions in UI tests.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-lock-view")
        .onAppear {
            // Skip the auto-unlock-on-appear in test mode: attemptUnlock()
            // succeeds instantly there (no real biometric prompt), which
            // would race ahead of any UI test assertion that the lock view
            // is shown. Tests must explicitly tap app-lock-unlock-button,
            // matching how a real user dismisses the lock screen.
            guard !appLockStore.isTestEnvironment else { return }
            unlock()
        }
        // A URL opened while locked (e.g. the Spotify OAuth callback) bumps
        // this counter: the onAppear attempt above is single-shot and can be
        // system-cancelled mid-activation when the app is opened via URL, so
        // the callback return must re-present the prompt itself. The
        // isAuthenticating guard in unlock() keeps this from double-prompting
        // over an attempt that is still in flight.
        .onChange(of: appLockStore.unlockPromptRequestCount) { _, _ in
            guard !appLockStore.isTestEnvironment else { return }
            unlock()
        }
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Dispatch"
    }

    private func unlock() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            _ = await appLockStore.attemptUnlock()
            isAuthenticating = false
        }
    }
}
