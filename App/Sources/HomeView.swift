import DispatchKit
import SwiftData
import SwiftUI

struct HomeView: View {
    @Query private var reports: [Report]
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    @Environment(ThemeStore.self) private var themeStore
    @Environment(AwakeStore.self) private var awakeStore
    @Environment(VisualizationFilterStore.self) private var filterStore
    @Environment(SurveyPresenter.self) private var surveyPresenter
    @Environment(NotificationScheduler.self) private var scheduler
    @Environment(\.notificationPrefs) private var notificationPrefs
    @State private var isShowingFilter = false

    private var theme: Theme { themeStore.theme }

    private var visibleQuestions: [Question] {
        questions.filter { $0.isEnabled && filterStore.isVisible($0.uniqueIdentifier) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.themeBackground(theme)
                    .ignoresSafeArea()

                VStack {
                    topBar
                    if reports.isEmpty {
                        Spacer()
                        hexagon
                        Text("\(reports.count) reports")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .accessibilityIdentifier("report-count")
                        Spacer()
                    } else {
                        filterPill
                        visualizationPages
                        Text("\(reports.count) reports")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .accessibilityIdentifier("report-count")
                    }
                    bottomBar
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $isShowingFilter) {
                VisualizationFilterView(
                    questions: questions.filter(\.isEnabled),
                    filterStore: filterStore
                )
            }
        }
    }

    private var filterPill: some View {
        Button {
            isShowingFilter = true
        } label: {
            Text("Filter Visualizations…")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.15))
                .clipShape(Capsule())
        }
        .accessibilityIdentifier("viz-filter-button")
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var visualizationPages: some View {
        if visibleQuestions.isEmpty {
            Spacer()
            Text("No visualizations to show")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        } else {
            TabView {
                ForEach(visibleQuestions, id: \.uniqueIdentifier) { question in
                    QuestionVisualizationView(
                        question: question,
                        visualization: VisualizationData.build(for: question, reports: reports),
                        theme: theme
                    )
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
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

            NavigationLink(destination: SettingsView()) {
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
            NavigationLink(destination: QuestionSettingsView()) {
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
                surveyPresenter.request = SurveyRequest(kind: .regular, trigger: .manual)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .accessibilityIdentifier("report-button")

            Spacer()

            Button(awakeStore.isAwake ? "AWAKE" : "ASLEEP") {
                // Toggling is authoritative even if the survey that follows is
                // cancelled — the state change reflects reality regardless of
                // whether the user files the optional report about it.
                let kind = awakeStore.toggle()
                scheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
                surveyPresenter.request = SurveyRequest(kind: kind, trigger: .manual)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .accessibilityIdentifier("awake-toggle")
        }
        .padding()
    }
}
