import DispatchKit
import SwiftUI

/// The dashboard's REPORT / (center) / AWAKE-ASLEEP action strip. iOS-only —
/// the Mac target has no SurveyPresenter/AwakeStore. Shared by HomeView (iPhone,
/// with page dots in the center) and LargeScreenShell's iPad dashboard (no dots).
struct DashboardActionBar<Center: View>: View {
    @Environment(SurveyPresenter.self) private var surveyPresenter
    @Environment(AwakeStore.self) private var awakeStore
    @Environment(NotificationScheduler.self) private var scheduler
    @Environment(\.notificationPrefs) private var notificationPrefs
    @ViewBuilder var center: () -> Center

    var body: some View {
        HStack {
            Button("REPORT") {
                // Guarded for the ⌘N path: a hardware-keyboard shortcut can
                // fire while the survey is already presented (the presenting
                // view stays in the responder chain under a sheet) — don't
                // stomp an in-progress survey's request.
                guard surveyPresenter.request == nil else { return }
                surveyPresenter.request = SurveyRequest(kind: .regular, trigger: .manual)
            }
            .font(.headline)
            .foregroundStyle(.white)
            // Sunk strip: keep a >=44pt hit target extending upward, away
            // from the home indicator (the indicator overlaps background only).
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            // Plan 27: new report from a hardware keyboard (iPad).
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityIdentifier("report-button")

            Spacer()
            center()
            Spacer()

            AwakePillToggle(isAwake: awakeStore.isAwake) {
                // Toggling is authoritative even if the survey that follows is
                // cancelled — the state change reflects reality regardless of
                // whether the user files the optional report about it.
                let kind = awakeStore.toggle()
                scheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
                surveyPresenter.request = SurveyRequest(kind: kind, trigger: .manual)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }
}

/// Plan 29: Reporter-style AWAKE/ASLEEP pill — a capsule whose white knob
/// slides edge-to-edge as the label swaps. Semantics live in `action`;
/// this view is presentation only. Internal (not `private`) so both HomeView
/// and `DashboardActionBar` can use it.
struct AwakePillToggle: View {
    let isAwake: Bool
    let action: () -> Void

    var body: some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            HStack(spacing: 8) {
                if !isAwake { knob }
                Text(isAwake ? "AWAKE" : "ASLEEP")
                    .font(.caption.weight(.bold))
                    .kerning(0.5)
                    .foregroundStyle(.white)
                if isAwake { knob }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.18)))
        }
        .accessibilityIdentifier("awake-toggle")
        // NavigationUITests reads .label and asserts AWAKE/ASLEEP + the flip.
        .accessibilityLabel(isAwake ? "AWAKE" : "ASLEEP")
    }

    private var knob: some View {
        Circle().fill(Color.white).frame(width: 18, height: 18)
    }
}
