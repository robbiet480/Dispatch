import DispatchKit
import SwiftUI

/// Settings → General: the app-wide theme color, plus the one line of context
/// a Mac user needs about where reports come from.
///
/// The pane itself is deliberately SYSTEM-NATIVE (plain grouped `Form`, no
/// theme applied to the chrome) — the theme colors the main window, not the
/// preferences window. `minWidth: 500` matches every other pane so switching
/// tabs never jumps the window width.
struct GeneralSettingsPane: View {
    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        Form {
            Section {
                Picker("Theme Color", selection: Binding(
                    get: { themeStore.theme },
                    set: { themeStore.theme = $0 }
                )) {
                    ForEach(Theme.allCases, id: \.self) { theme in
                        HStack {
                            Circle()
                                .fill(ThemeColor.color(theme))
                                .frame(width: 12, height: 12)
                            Text(theme.displayName)
                        }
                        .tag(theme)
                    }
                }
                .accessibilityIdentifier("theme-picker")
            } header: {
                Text("Appearance")
            } footer: {
                Text("The theme colors the main window. Reports are filed on your iPhone or Apple Watch and sync here — the Mac app is for reviewing, analyzing, and exporting.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500)
    }
}
