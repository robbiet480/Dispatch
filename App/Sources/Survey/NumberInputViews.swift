import DispatchKit
import SwiftUI

/// Number-question input controls (plan 21). Every control writes the same
/// `numericResponse` string the plain text field produces, through the same
/// `Binding<String>` — storage, export, visualization, and default-answer
/// logic are untouched. An empty string means untouched/skipped; controls
/// only write on interaction (there is no keyboard, so the survey's
/// flush-registry path is deliberately a no-op for all of them).
///
/// Accessibility bar (plan 17): the custom controls (dial, tap counter,
/// scale) are `.accessibilityAdjustable` with value announcements; the
/// system-derived slider/stepper inherit their native adjustable behavior.
/// All value labels use scalable text styles so Dynamic Type (incl. XXL and
/// accessibility sizes) survives.
enum NumberInputFormat {
    /// Formats a control value the way it should be filed AND displayed:
    /// integer display when the step (and the value) are whole numbers,
    /// plain decimal otherwise. Mirrors what a user would have typed.
    static func string(from value: Double, step: Double) -> String {
        if step.truncatingRemainder(dividingBy: 1) == 0,
           value.truncatingRemainder(dividingBy: 1) == 0,
           value.magnitude < 1e15 { // Int-conversion safety
            return String(Int(value))
        }
        return String(value)
    }

    /// Snaps a raw control value onto the min-anchored step grid, clamped
    /// into the configured range.
    static func snapped(_ raw: Double, config: (min: Double, max: Double, step: Double)) -> Double {
        let stepped = config.min + ((raw - config.min) / config.step).rounded() * config.step
        return min(max(stepped, config.min), config.max)
    }
}

/// Shared plumbing: parse the current answer string (empty = untouched).
private func currentValue(of string: String) -> Double? {
    Double(string.trimmingCharacters(in: .whitespaces))
}

// MARK: - Slider

/// System slider dressed with a large value label above (spec §Styles).
struct SliderInput: View {
    @Binding var value: String
    let config: (min: Double, max: Double, step: Double)

    private var current: Double {
        min(max(currentValue(of: value) ?? config.min, config.min), config.max)
    }

    private var display: String {
        value.isEmpty ? NumberInputFormat.string(from: config.min, step: config.step) : value
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(display)
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .opacity(value.isEmpty ? 0.4 : 1) // dimmed until touched
                .accessibilityHidden(true) // the slider announces the value
            Slider(
                value: Binding(
                    get: { current },
                    set: { newValue in
                        let snapped = NumberInputFormat.snapped(newValue, config: config)
                        value = NumberInputFormat.string(from: snapped, step: config.step)
                    }),
                in: config.min...config.max,
                step: config.step)
                .accessibilityIdentifier("number-slider")
                .accessibilityValue(display)
        }
        .padding()
    }
}

// MARK: - Stepper

/// System stepper (native long-press repeat) with a large value readout.
struct StepperInput: View {
    @Binding var value: String
    let config: (min: Double, max: Double, step: Double)

    private var current: Double {
        min(max(currentValue(of: value) ?? config.min, config.min), config.max)
    }

    private var display: String {
        value.isEmpty ? NumberInputFormat.string(from: config.min, step: config.step) : value
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(display)
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .opacity(value.isEmpty ? 0.4 : 1)
                .accessibilityHidden(true) // the stepper announces the value
            Stepper(
                value: Binding(
                    get: { current },
                    set: { newValue in
                        let snapped = NumberInputFormat.snapped(newValue, config: config)
                        value = NumberInputFormat.string(from: snapped, step: config.step)
                    }),
                in: config.min...config.max,
                step: config.step) {
                    EmptyView()
                }
                .labelsHidden()
                .accessibilityIdentifier("number-stepper")
                .accessibilityValue(display)
        }
        .padding()
    }
}

// MARK: - Dial

/// Custom rotary drag control — the whimsy option. Dragging around the ring
/// maps the angle from 12 o'clock to min…max, snapped to the step grid.
struct DialInput: View {
    @Binding var value: String
    let config: (min: Double, max: Double, step: Double)

    /// Dial diameter; scales with Dynamic Type so the label never clips.
    @ScaledMetric(relativeTo: .largeTitle) private var diameter: CGFloat = 220

    private var current: Double {
        min(max(currentValue(of: value) ?? config.min, config.min), config.max)
    }

    private var fraction: Double {
        (current - config.min) / (config.max - config.min)
    }

    private var display: String {
        value.isEmpty ? NumberInputFormat.string(from: config.min, step: config.step) : value
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 14)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90)) // progress starts at 12 o'clock
            // Knob marker at the current angle.
            Circle()
                .fill(.tint)
                .frame(width: 26, height: 26)
                .offset(y: -diameter / 2)
                .rotationEffect(.degrees(fraction * 360))
            Text(display)
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .opacity(value.isEmpty ? 0.4 : 1)
        }
        .frame(width: diameter, height: diameter)
        // Gesture attaches HERE, before the width-expanding frame/padding,
        // so drag locations are in the dial's own diameter×diameter space.
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    // Angle from the dial center, 0° at 12 o'clock, clockwise.
                    let center = CGPoint(x: diameter / 2, y: diameter / 2)
                    let dx = gesture.location.x - center.x
                    let dy = gesture.location.y - center.y
                    var degrees = atan2(dx, -dy) * 180 / .pi // 0 at top, CW positive
                    if degrees < 0 { degrees += 360 }
                    write(config.min + (degrees / 360) * (config.max - config.min))
                })
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement()
        .accessibilityIdentifier("number-dial")
        .accessibilityLabel("Dial")
        .accessibilityValue(display)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: write(current + config.step)
            case .decrement: write(current - config.step)
            @unknown default: break
            }
        }
    }

    private func write(_ raw: Double) {
        let snapped = NumberInputFormat.snapped(raw, config: config)
        value = NumberInputFormat.string(from: snapped, step: config.step)
    }
}

// MARK: - Tap counter

/// Huge increment button that counts taps; long-press decrements.
/// Skipped-vs-zero semantics (spec §Styles): untouched shows a dimmed 0 and
/// files nothing (empty string = skipped); once the user has interacted,
/// "0" is a real answer — including a long-press decrement at 0.
struct TapCounterInput: View {
    @Binding var value: String
    let config: (min: Double, max: Double, step: Double)

    @ScaledMetric(relativeTo: .largeTitle) private var diameter: CGFloat = 200

    private var count: Double {
        currentValue(of: value) ?? 0
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.15))
                Circle()
                    .stroke(.tint, lineWidth: 4)
                Text(value.isEmpty ? "0" : value)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .opacity(value.isEmpty ? 0.4 : 1)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .onTapGesture { increment() }
            .onLongPressGesture(minimumDuration: 0.4) { decrement() }
            Text("TAP TO COUNT · HOLD TO UNDO")
                .font(.caption.weight(.semibold))
                .kerning(1.0)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true) // hint below covers this
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement()
        .accessibilityIdentifier("number-tap-counter")
        .accessibilityLabel("Tap counter")
        .accessibilityValue(value.isEmpty ? "Not counted yet" : value)
        .accessibilityHint("Adjust up to count, down to undo a count.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: increment()
            case .decrement: decrement()
            @unknown default: break
            }
        }
    }

    private func increment() {
        write(count + config.step)
    }

    private func decrement() {
        write(count - config.step)
    }

    /// Any interaction produces a real answer — clamped to 0…max, and "0"
    /// stays filed (never reset to the empty/skipped string).
    private func write(_ raw: Double) {
        let clamped = min(max(raw, 0), config.max)
        value = NumberInputFormat.string(from: clamped, step: config.step)
    }
}

// MARK: - Rating scale

/// Row of tappable dots (default 1–5) with selected-state fill. Tapping the
/// selected dot clears it back to skipped, mirroring the choice-list toggle.
struct ScaleInput: View {
    @Binding var value: String
    let config: (min: Double, max: Double, step: Double)

    @ScaledMetric(relativeTo: .title3) private var dotSize: CGFloat = 44

    /// Integer scale points. Defensively capped so a config meant for a
    /// slider (say 0–1000) can't render a thousand dots.
    private var points: [Int] {
        let low = Int(config.min)
        let high = max(low, Int(config.max))
        return Array(low...min(high, low + 19))
    }

    private var selected: Int? {
        currentValue(of: value).map { Int($0) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(points, id: \.self) { point in
                    Button {
                        select(point)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(selected == point ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                            Text("\(point)")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(selected == point ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                        }
                        .frame(width: dotSize, height: dotSize)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true) // the container is the adjustable element
                }
            }
            .padding()
        }
        .accessibilityElement()
        .accessibilityIdentifier("number-scale")
        .accessibilityLabel("Rating scale")
        .accessibilityValue(selected.map { "\($0) of \(points.last ?? $0)" } ?? "No rating")
        .accessibilityAdjustableAction { direction in
            let current = selected ?? (points.first.map { $0 - 1 } ?? 0)
            switch direction {
            case .increment: if let next = points.first(where: { $0 > current }) { select(next, toggle: false) }
            case .decrement: if let previous = points.last(where: { $0 < current }) { select(previous, toggle: false) }
            @unknown default: break
            }
        }
    }

    private func select(_ point: Int, toggle: Bool = true) {
        if toggle, selected == point {
            value = "" // deselect → skipped, like tapping a selected choice
        } else {
            value = String(point)
        }
    }
}
