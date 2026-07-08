import DispatchKit
import SwiftUI

struct ReportDetailView: View {
    let report: Report
    @Environment(ThemeStore.self) private var themeStore

    private var theme: Theme { themeStore.theme }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                sensorSection
                responseSections
                footerSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(timeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - Sensors

    @ViewBuilder
    private var sensorSection: some View {
        let rows = sensorRows
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.label) { row in
                    sensorRow(icon: row.icon, label: row.label, value: row.value)
                }
            } header: {
                sectionHeader("SENSORS")
            }
        }
    }

    private var sensorRows: [(icon: String, label: String, value: String)] {
        var rows: [(icon: String, label: String, value: String)] = []

        if let place = placeText {
            rows.append(("mappin.and.ellipse", "Place", place))
        }
        if let weather = report.weather {
            var parts: [String] = []
            if let condition = weather.condition, !condition.isEmpty { parts.append(condition) }
            if let tempF = weather.tempF { parts.append(String(format: "%.0f°F", tempF)) }
            if !parts.isEmpty {
                rows.append(("cloud.sun.fill", "Weather", parts.joined(separator: ", ")))
            }
        }
        if let meters = report.altitudeMeters {
            let feet = meters * 3.28084
            rows.append(("arrow.up.forward", "Altitude", String(format: "%.0f ft", feet)))
        }
        if let audio = report.audio {
            let display = AudioLevel.displayValue(fromRaw: audio.avg)
            let label = AudioLevel.label(forDisplay: display)
            rows.append(("waveform", "Sound", String(format: "%.1f dB · %@", display, label)))
        }
        if let steps = healthValue("steps") {
            rows.append(("figure.walk", "Steps", String(format: "%.0f", steps)))
        }
        if let flights = healthValue("flightsClimbed") {
            rows.append(("figure.stairs", "Flights climbed", String(format: "%.0f", flights)))
        }
        if let battery = report.battery {
            rows.append(("battery.75percent", "Battery", String(format: "%.0f%%", battery * 100)))
        }
        if let focus = report.focus {
            let value = focus.isFocused ? (focus.label ?? "On") : "Off"
            rows.append(("moon.circle", "Focus", value))
        }
        if let connection = report.connectionType {
            let value: String
            switch connection {
            case .cellular: value = "Cellular"
            case .wifi: value = "Wi-Fi"
            case .none: value = "None"
            }
            rows.append(("antenna.radiowaves.left.and.right", "Connection", value))
        }
        return rows
    }

    private func healthValue(_ type: String) -> Double? {
        report.health.first { $0.type == type }?.value
    }

    private var placeText: String? {
        guard let placemark = report.location?.placemark else { return nil }
        let parts = [placemark.name, placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func sensorRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 24)
            Text(label)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(value)
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .listRowBackground(Color.white.opacity(0.12))
    }

    // MARK: - Responses

    @ViewBuilder
    private var responseSections: some View {
        let answered = report.responses.filter { answerText(for: $0) != nil }
        if !answered.isEmpty {
            Section {
                ForEach(answered, id: \.uniqueIdentifier) { response in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(response.questionPrompt.uppercased())
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white.opacity(0.7))
                        Text(answerText(for: response) ?? "")
                            .font(.body)
                            .foregroundStyle(.white)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.white.opacity(0.12))
                }
            } header: {
                sectionHeader("RESPONSES")
            }
        }
    }

    private func answerText(for response: Response) -> String? {
        if let tokens = response.tokens, !tokens.isEmpty {
            return tokens.map(\.text).joined(separator: " · ")
        }
        if let options = response.answeredOptions, !options.isEmpty {
            return options.joined(separator: ", ")
        }
        if let notes = response.textResponses, !notes.isEmpty {
            return notes.map(\.text).joined(separator: "\n")
        }
        if let numeric = response.numericResponse, !numeric.isEmpty {
            return numeric
        }
        if let location = response.locationResponse,
           let text = location.text, !text.isEmpty {
            return text
        }
        return nil
    }

    // MARK: - Footer

    private var footerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                if report.isBackdated {
                    backdatedChip
                }
                Text("\(report.kind.rawValue.capitalized) report · \(report.trigger.rawValue)")
                Text(report.timeZoneIdentifier)
                Text(exactTimestamp)
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))
            .listRowBackground(Color.clear)
        }
    }

    private var backdatedChip: some View {
        Text("BACKDATED")
            .font(.caption2)
            .fontWeight(.bold)
            .kerning(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.25), in: Capsule())
            .accessibilityIdentifier("backdated-chip")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }

    private var timeTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: report.timeZoneIdentifier) ?? .gmt
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: report.date)
    }

    private var exactTimestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: report.timeZoneIdentifier) ?? .gmt
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return formatter.string(from: report.date)
    }
}
