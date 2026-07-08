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
    public var isLocked: Bool = false

    /// Backgrounding this long or longer re-locks the app on return.
    public static let backgroundGraceInterval: TimeInterval = 60

    public let isTestEnvironment: Bool

    public init(defaults: UserDefaults = .standard, isTestEnvironment: Bool? = nil) {
        self.defaults = defaults
        self._enabled = defaults.bool(forKey: "privacy.appLockEnabled")
        self.isTestEnvironment = isTestEnvironment ?? {
            let arguments = ProcessInfo.processInfo.arguments
            return arguments.contains("--mock-sensors") || arguments.contains("--ui-testing")
        }()
    }

    public var enabled: Bool {
        get { _enabled }
        set {
            _enabled = newValue
            defaults.set(newValue, forKey: "privacy.appLockEnabled")
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

    /// Call when the scene becomes active again after having backgrounded
    /// at `backgroundedAt`. Locks only if enabled and the grace interval elapsed.
    public func evaluateReturnFromBackground(backgroundedAt: Date?) {
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
