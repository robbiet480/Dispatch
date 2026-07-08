import DispatchKit
import SwiftUI
import UIKit

/// Window-level privacy cover. Owns a separate `UIWindow` layered above
/// everything (`.alert + 1`) so the cover always wins over any SwiftUI
/// presentation state (sheets, fullScreenCovers) underneath it.
///
/// `show()`/`hide()` are synchronous main-thread calls by design: the cover
/// must be on screen before the system takes the app-switcher snapshot and
/// before the first frame after reactivation — any async hop (Task, animation,
/// fullScreenCover transition) reintroduces the split-second content flash
/// this exists to prevent.
@MainActor
final class PrivacyCoverWindow {
    private var window: UIWindow?
    private let appLockStore: AppLockStore
    private let themeStore: ThemeStore

    nonisolated init(appLockStore: AppLockStore, themeStore: ThemeStore) {
        self.appLockStore = appLockStore
        self.themeStore = themeStore
    }

    /// Shows the cover window immediately. No-op if already showing or no
    /// window scene exists yet (e.g. before the scene connects at launch).
    func show() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: {
            $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
        }) ?? scenes.first else { return }

        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        cover.rootViewController = UIHostingController(
            rootView: PrivacyCoverView(onDismiss: { [weak self] in self?.hide() })
                .environment(appLockStore)
                .environment(themeStore)
        )
        cover.isHidden = false
        window = cover
    }

    /// Hides and releases the cover window immediately.
    func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// Content hosted by `PrivacyCoverWindow`. When the app is locked it shows
/// the full `AppLockView` (with the unlock flow); when merely covered for
/// backgrounding (grace interval not yet decided) it shows the same themed
/// background and lock glyph without an Unlock button — no auth is needed
/// to return within the grace window, the view just hides content from the
/// app switcher snapshot.
struct PrivacyCoverView: View {
    @Environment(AppLockStore.self) private var appLockStore
    @Environment(ThemeStore.self) private var themeStore

    /// Called when the window should tear itself down: neither locked nor
    /// covered anymore (e.g. a successful unlock from AppLockView).
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            if appLockStore.isLocked {
                AppLockView()
            } else {
                Color.themeBackground(themeStore.theme)
                    .ignoresSafeArea()
                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white)
            }
        }
        .onChange(of: appLockStore.isLocked) { _, isLocked in
            if !isLocked, !appLockStore.isCovered {
                onDismiss()
            }
        }
    }
}
