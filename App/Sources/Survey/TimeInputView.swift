import DispatchKit
import SwiftUI

/// Time-question input (plan 28). Wheel `DatePicker(.hourAndMinute)`
/// seeded to the current time, a prominent "Now" button that one-taps
/// the current wall-clock minute, and a "Yesterday" chip toggling
/// `dayOffset` between 0 and -1. Untouched = skipped (the number-control
/// convention): the wheel display dims until the first interaction, and
/// only interactions write `.time` through `onAnswer`. No keyboard, so
/// nothing registers with the survey's flush registry.
struct TimeInput: View {
    let value: TimeAnswer? // nil = untouched
    let onAnswer: (TimeAnswer) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(current.displayText())
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .opacity(value == nil ? 0.4 : 1) // dimmed until touched
                .accessibilityHidden(true) // the picker announces the value
            DatePicker("Time", selection: wheelBinding, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .accessibilityIdentifier("time-picker")
            HStack(spacing: 12) {
                Button("Now") { onAnswer(TimeAnswer.now()) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("time-now")
                YesterdayChip(isOn: current.dayOffset == -1) {
                    // Toggling commits the currently displayed wheel time.
                    onAnswer(TimeAnswer(minutesSinceMidnight: current.minutesSinceMidnight,
                                        dayOffset: current.dayOffset == -1 ? 0 : -1))
                }
            }
        }
        .padding()
    }

    /// The answer being displayed: the stored value, or "now" while untouched.
    private var current: TimeAnswer { value ?? .now() }

    /// Wheel Date ⇄ TimeAnswer bridge: only the hour/minute components matter;
    /// any wheel movement commits an answer (preserving the chip's offset).
    private var wheelBinding: Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.current
                let minutes = current.clampedMinutes
                return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60,
                                     second: 0, of: Date()) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                onAnswer(TimeAnswer(minutesSinceMidnight: minutes, dayOffset: current.dayOffset))
            })
    }
}

/// Capsule toggle for the "Yesterday" day offset. Filled when selected;
/// carries the accessibility identifier/label/selected trait the UI suite and
/// VoiceOver rely on. Text scales with Dynamic Type (plan-17 bar).
struct YesterdayChip: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Yesterday")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                )
                .foregroundStyle(isOn ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("time-yesterday")
        .accessibilityLabel("Yesterday")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
