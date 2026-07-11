import DispatchKit
import SwiftData
import SwiftUI

/// Placeholder root (plan 36 Task 3) — replaced by the reports split view in
/// Task 4. Proves the store + CloudKit boot end to end: the report count is
/// live @Query data from the synced container.
struct MacRootView: View {
    @Query private var reports: [Report]
    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        ZStack {
            Color.themeBackground(themeStore.theme)
                .ignoresSafeArea()
            Text("\(reports.count) reports")
                .font(.title2)
                .foregroundStyle(.white)
        }
    }
}
