import DispatchKit
import SwiftUI

struct CaptureChecklistView: View {
    let outcomes: [SensorKind: SensorOutcome]

    @State private var expandedKind: SensorKind?

    private static let rows: [(SensorKind, String, String)] = [
        (.location, "mappin", "LOCATION"),
        (.weather, "cloud.fill", "WEATHER CONDITIONS"),
        (.altitude, "mountain.2.fill", "ALTITUDE"),
        (.photos, "camera.fill", "PHOTOS"),
        (.audio, "mic.fill", "AUDIO"),
        (.healthSteps, "figure.walk", "STEPS"),
        (.healthFlights, "stairs", "STAIRS"),
        (.healthActivityRings, "circle.circle", "ACTIVITY RINGS"),
        (.healthMedications, "pills", "MEDICATIONS"),
    ]

    /// Medications captured with ZERO readings is the granted-but-nothing-
    /// logged success case (default-ON sensor, most users log no doses) —
    /// showing "MEDICATIONS CAPTURED" or a failure row for it would be
    /// noise, so the row disappears entirely.
    private var visibleRows: [(SensorKind, String, String)] {
        Self.rows.filter { kind, _, _ in
            guard kind == .healthMedications,
                  case .captured(.health(let readings)) = outcomes[kind] else { return true }
            return !readings.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(visibleRows, id: \.0) { kind, icon, label in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Image(systemName: icon).frame(width: 24)
                        Text(text(for: kind, label: label))
                            .font(.subheadline.weight(.semibold))
                            .kerning(1.2)
                    }
                    .opacity(outcomes[kind] == nil ? 0.55 : 1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard isTappable(kind) else { return }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expandedKind = (expandedKind == kind) ? nil : kind
                        }
                    }
                    .accessibilityIdentifier("sensor-row-\(kind.rawValue)")

                    if expandedKind == kind, let hint = hint(for: kind) {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 36)
                            .accessibilityIdentifier("sensor-hint-\(kind.rawValue)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private func isTappable(_ kind: SensorKind) -> Bool {
        switch outcomes[kind] {
        case .unavailable, .disabled: true
        default: false
        }
    }

    private func hint(for kind: SensorKind) -> String? {
        switch outcomes[kind] {
        case .unavailable(let reason):
            SensorFailureHint.hint(for: kind, reason: reason)
        case .disabled:
            SensorFailureHint.disabledHint(for: kind)
        default:
            nil
        }
    }

    private func text(for kind: SensorKind, label: String) -> String {
        switch outcomes[kind] {
        case nil: "GETTING \(label)…"
        case .disabled: "\(label) OFF"
        case .unavailable: "UNABLE TO DETECT \(label)"
        case .captured(let payload): captured(payload, label: label)
        }
    }

    private func captured(_ payload: SensorPayload, label: String) -> String {
        switch payload {
        case .location(let snapshot):
            let place = [snapshot.placemark?.locality, snapshot.placemark?.administrativeArea]
                .compactMap(\.self).joined(separator: ", ")
            return place.isEmpty ? "LOCATION CAPTURED" : place.uppercased()
        case .weather(let observation):
            return (observation.condition ?? "WEATHER CAPTURED").uppercased()
        case .altitude(let meters):
            return "\(Int(meters * 3.28084)) FEET"
        case .photos(let count, _):
            return "\(count) PHOTOS ADDED"
        case .audio(let sample):
            let display = AudioLevel.displayValue(fromRaw: sample.avg)
            return "\(AudioLevel.label(forDisplay: display)) \(String(format: "%.2f", display)) DB"
        case .health(let readings):
            if let steps = readings.first(where: { $0.type == "steps" }) {
                return "\(Int(steps.value).formatted()) STEPS TAKEN"
            }
            if let flights = readings.first(where: { $0.type == "flightsClimbed" }) {
                // Original Reporter parity: "7 STAIRCASES UP · 2 DOWN" when
                // the pedometer supplied a descended count.
                if let descended = readings.first(where: { $0.type == "flightsDescended" }) {
                    return "\(Int(flights.value)) STAIRCASES UP · \(Int(descended.value)) DOWN"
                }
                return "\(Int(flights.value)) STAIRCASES"
            }
            if let rings = ActivityRingsFormatter.checklistLine(from: readings) {
                return rings
            }
            let medications = readings.filter { MedicationReading.parse($0.type) != nil }
            if !medications.isEmpty {
                return "\(medications.count) MEDICATION\(medications.count == 1 ? "" : "S") LOGGED"
            }
            return "\(label) CAPTURED"
        case .battery, .connection, .focus:
            return "\(label) CAPTURED"
        }
    }
}
