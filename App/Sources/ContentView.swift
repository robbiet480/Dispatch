import DispatchKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Query private var reports: [Report]
    @State private var showingSurvey = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "hexagon.fill")
                .font(.system(size: 96))
                .foregroundStyle(.white.opacity(0.35))
            Text("\(reports.count) reports")
                .font(.subheadline)
                .foregroundStyle(.white)
                .accessibilityIdentifier("report-count")
            Spacer()
            HStack {
                Button("REPORT") { showingSurvey = true }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("report-button")
                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.98, green: 0.36, blue: 0.22))
        .fullScreenCover(isPresented: $showingSurvey) {
            SurveyFlowView(kind: .regular, trigger: .manual)
        }
    }
}
