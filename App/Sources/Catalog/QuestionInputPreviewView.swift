import DispatchKit
import SwiftUI

/// Non-interactive preview of a question's input control. Mirrors the survey
/// controls' appearance with static primitives — it never binds to a live
/// answer — so it renders identically on iOS and macOS inside the catalog
/// detail. Whole subtree is inert.
struct QuestionInputPreviewView: View {
    let control: QuestionPreviewControl

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            Text("Non-interactive preview")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(true)
        .allowsHitTesting(false)
        .accessibilityIdentifier("question-input-preview")
    }

    @ViewBuilder private var content: some View {
        switch control {
        case .number(let n): number(n)
        case .choices(let options, let multi, let selected): choices(options, multi, selected)
        case .yesNo(let selected): yesNo(selected)
        case .tokens(let samples): chips(samples)
        case .people(let sample): chips([sample], systemImage: "person.crop.circle")
        case .location: row(systemImage: "mappin.and.ellipse", text: "Current location")
        case .note(let placeholder): noteField(placeholder)
        case .time(let sample): pill(sample, systemImage: "clock")
        }
    }

    @ViewBuilder private func number(_ n: QuestionPreviewControl.NumberPreview) -> some View {
        switch n {
        case .textField(let placeholder, let value):
            fieldBox(value ?? placeholder ?? "0")
        case .slider(let lo, let hi, let value):
            VStack(spacing: 4) {
                Slider(value: .constant(value), in: lo...hi)
                    .tint(.white)
                HStack {
                    Text(trimmed(lo)); Spacer(); Text(trimmed(hi))
                }.font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
        case .dial(let lo, let hi, let value):
            dial(fraction: hi > lo ? (value - lo) / (hi - lo) : 0, label: trimmed(value))
        case .stepper(let value):
            HStack(spacing: 12) {
                stepButton("minus"); Text(trimmed(value)).font(.title3.monospacedDigit()).foregroundStyle(.white)
                stepButton("plus")
            }
        case .tapCounter(let value):
            VStack(spacing: 6) {
                Text("\(value)").font(.system(size: 34, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                pill("+1", systemImage: "plus")
            }
        case .scale(let points, let selected):
            HStack(spacing: 8) {
                ForEach(points, id: \.self) { p in
                    Text("\(p)")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(p == selected ? Color.white.opacity(0.9) : Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(p == selected ? Color.black.opacity(0.8) : .white)
                        .font(.subheadline)
                }
            }
        }
    }

    private func choices(_ options: [String], _ multi: Bool, _ selected: Int?) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { idx, option in
                HStack {
                    Image(systemName: multi
                          ? (idx == selected ? "checkmark.square.fill" : "square")
                          : (idx == selected ? "largecircle.fill.circle" : "circle"))
                    Text(option); Spacer()
                }
                .foregroundStyle(.white)
                .padding(10)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func yesNo(_ selected: Bool?) -> some View {
        HStack(spacing: 10) {
            ForEach([true, false], id: \.self) { value in
                Text(value ? "Yes" : "No")
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(selected == value ? Color.white.opacity(0.9) : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(selected == value ? Color.black.opacity(0.8) : .white)
            }
        }
    }

    private func chips(_ items: [String], systemImage: String? = nil) -> some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Label {
                    Text(item)
                } icon: {
                    if let systemImage { Image(systemName: systemImage) }
                }
                .labelStyle(.titleAndIcon)
                .font(.subheadline).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.white.opacity(0.12), in: Capsule())
            }
            Text("＋").foregroundStyle(.white.opacity(0.5))
        }
    }

    private func noteField(_ placeholder: String?) -> some View {
        Text(placeholder ?? "Write a note…")
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            .padding(10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func fieldBox(_ text: String) -> some View {
        Text(text).foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(systemImage: String, text: String) -> some View {
        Label(text, systemImage: systemImage).foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func pill(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage).font(.subheadline).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.white.opacity(0.12), in: Capsule())
    }

    private func stepButton(_ systemImage: String) -> some View {
        Image(systemName: systemImage).foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.12), in: Circle())
    }

    private func dial(fraction: Double, label: String) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 8)
            Circle().trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label).foregroundStyle(.white).font(.headline)
        }
        .frame(width: 92, height: 92)
    }

    private func trimmed(_ value: Double) -> String {
        // Format directly — `Int(value)` traps for an extreme bound (e.g. the
        // `.greatestFiniteMagnitude` "no max" of a stepper/tapCounter config).
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
