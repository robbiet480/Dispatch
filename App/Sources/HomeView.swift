import DispatchKit
import SwiftData
import SwiftUI

struct HomeView: View {
    @Query private var reports: [Report]
    @State private var showingSurvey = false
    @State private var surveyKind: ReportKind = .regular
    @State private var awakeStore = AwakeStore()
    @State private var isAwake: Bool

    init() {
        _isAwake = State(initialValue: AwakeStore().isAwake)
    }

    private var theme: Theme { ThemeStore().theme }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.themeBackground(theme)
                    .ignoresSafeArea()

                VStack {
                    topBar
                    Spacer()
                    hexagon
                    Text("\(reports.count) reports")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("report-count")
                    Spacer()
                    bottomBar
                }
            }
            .navigationBarHidden(true)
        }
        .fullScreenCover(isPresented: $showingSurvey) {
            SurveyFlowView(kind: surveyKind, trigger: .manual)
        }
    }

    private var topBar: some View {
        HStack {
            NavigationLink(destination: ReportsListView()) {
                Image(systemName: "list.bullet")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("reports-list-button")

            Spacer()

            NavigationLink(destination: Text("Settings")) {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("settings-button")
        }
        .padding()
    }

    @ViewBuilder
    private var hexagon: some View {
        if reports.isEmpty {
            NavigationLink(destination: Text("Questions coming in Task 5")) {
                ZStack {
                    Image(systemName: "hexagon.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("Edit your questions")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
            }
            .accessibilityIdentifier("home-hexagon")
        } else {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 96))
                .foregroundStyle(.white.opacity(0.35))
                .accessibilityIdentifier("home-hexagon")
        }
    }

    private var bottomBar: some View {
        HStack {
            Button("REPORT") {
                surveyKind = .regular
                showingSurvey = true
            }
            .font(.headline)
            .foregroundStyle(.white)
            .accessibilityIdentifier("report-button")

            Spacer()

            Button(isAwake ? "AWAKE" : "ASLEEP") {
                // Toggling is authoritative even if the survey that follows is
                // cancelled — the state change reflects reality regardless of
                // whether the user files the optional report about it.
                let kind = awakeStore.toggle()
                isAwake = awakeStore.isAwake
                surveyKind = kind
                showingSurvey = true
            }
            .font(.headline)
            .foregroundStyle(.white)
            .accessibilityIdentifier("awake-toggle")
        }
        .padding()
    }
}
