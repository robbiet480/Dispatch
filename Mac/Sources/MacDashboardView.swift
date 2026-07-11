import DispatchKit
import SwiftData
import SwiftUI

/// Placeholder (plan 36 Task 4) — the visualization grid lands in Task 5.
struct MacDashboardView: View {
    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        ZStack {
            Color.themeBackground(themeStore.theme)
                .ignoresSafeArea()
            Text("Dashboard")
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}
