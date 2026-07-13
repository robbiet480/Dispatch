import SwiftUI

extension View {
    /// Inline navigation title on iPhone/iPad; no-op on macOS (no nav bar).
    @ViewBuilder func inlineNavTitleOnPhone() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Dark nav-bar chrome so white text reads on the themed background; iOS only.
    @ViewBuilder func darkNavBarOnPhone() -> some View {
        #if os(iOS)
        self.toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }
}
