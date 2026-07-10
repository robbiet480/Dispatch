import Foundation
import DispatchKit
import SwiftData

/// Curated demo fixture for App Store screenshots (`--demo-data`, plan 23).
///
/// Only reachable from the test environment (`--ui-testing`/`--mock-sensors`
/// in-memory store): DispatchApp gates the call site, so production launches
/// can never seed this. Deterministic by construction — a seeded LCG drives
/// every varying choice, so two runs produce pixel-identical visualizations.
///
/// Shape: ~30 reports across the last 14 days (2–3 per day, all inside the
/// digest's "this week" window for the newest 7), with varied tokens/people/
/// places, numeric trends for the graphs, workout + activity-ring readings,
/// weather, focus states, and a couple of prompt groups for the editor shot.
enum DemoData {
    static func seed(into context: ModelContext) throws {
        // The default questions are seeded before this runs; join responses
        // to them by identifier + prompt exactly as the survey filer does.
        let questions = try context.fetch(FetchDescriptor<Question>())
        func question(_ slug: String) -> Question? {
            let id = DefaultQuestions.all.first { $0.slug == slug }?.identifier
            return questions.first { $0.uniqueIdentifier == id }
        }

        var rng = LCG(seed: 0xD15A7C4)

        let activities = ["coding", "reading", "meetings", "cooking", "walking",
                          "writing", "gym", "coffee", "errands", "music"]
        let people = ["Angela", "Sam", "Maya", "Jordan"]
        let places: [(name: String, lat: Double, lon: Double)] = [
            ("Home", 37.7599, -122.4148),
            ("Office", 37.7897, -122.4011),
            ("Gym", 37.7681, -122.4258),
            ("Blue Bottle", 37.7764, -122.4231),
            ("Golden Gate Park", 37.7694, -122.4862),
        ]
        let conditions = ["Clear", "Partly Cloudy", "Cloudy", "Fog", "Drizzle"]
        let lessons = [
            "SwiftData relationships must be optional for CloudKit.",
            "The best coffee ratio is 1:16.",
            "CLVisit monitoring costs almost no battery.",
            "Sourdough needs a colder proof than I thought.",
            "Charts read better with fewer colors.",
        ]

        let calendar = Calendar.current
        let now = Date()
        var reportIndex = 0

        for dayOffset in stride(from: 13, through: 0, by: -1) {
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -dayOffset, to: now) ?? now)
            let weekday = calendar.component(.weekday, from: day)
            let isWeekend = weekday == 1 || weekday == 7
            let reportsToday = 2 + Int(rng.next() % 2) // 2–3

            // Morning wake report — the sleep question is the FIRST home viz
            // page, so it must have data or the hero screenshot is empty.
            if let wakeDate = calendar.date(bySettingHour: 7, minute: 15 + Int(rng.next() % 40),
                                            second: 0, of: day), wakeDate <= now {
                let wake = Report()
                wake.uniqueIdentifier = "demo-wake-\(dayOffset)"
                wake.date = wakeDate
                wake.timeZoneIdentifier = TimeZone.current.identifier
                wake.kind = .wake
                wake.trigger = .wake
                wake.battery = 0.9
                let roll = rng.next() % 10
                let quality = roll < 6 ? "Great" : (roll < 9 ? "OK" : "Poorly")
                let sleepAnswer = answer(question("how-did-you-sleep"), options: [quality])
                context.insert(wake)
                context.insert(sleepAnswer)
                sleepAnswer.report = wake
                reportIndex += 1
            }

            for slot in 0..<reportsToday {
                let hour = [9, 14, 19][slot % 3] + Int(rng.next() % 2)
                let minute = Int(rng.next() % 60)
                guard let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                      date <= now else { continue }

                let report = Report()
                report.uniqueIdentifier = "demo-report-\(reportIndex)"
                report.date = date
                report.timeZoneIdentifier = TimeZone.current.identifier
                report.kind = .regular
                report.trigger = slot == 0 ? .manual : .notification
                report.battery = 0.35 + Double(rng.next() % 60) / 100.0
                report.connection = Int(rng.next() % 2)
                report.audio = AudioSample(avg: -60 + Double(rng.next() % 25), peak: -38)

                // Place: office on weekday middays, gym some evenings, else varied.
                let place: (name: String, lat: Double, lon: Double)
                let isGymVisit = slot == 2 && rng.next() % 3 == 0
                if isGymVisit {
                    place = places[2]
                } else if !isWeekend && slot == 1 {
                    place = places[1]
                } else {
                    place = places[Int(rng.next() % UInt64(places.count))]
                }
                var snapshot = LocationSnapshot(latitude: place.lat, longitude: place.lon)
                var placemark = Placemark()
                placemark.name = place.name
                placemark.locality = "San Francisco"
                snapshot.placemark = placemark
                snapshot.timestamp = date
                report.location = snapshot

                var weather = WeatherObservation()
                weather.tempF = 55 + Double(rng.next() % 18)
                weather.tempC = ((weather.tempF ?? 60) - 32) * 5 / 9
                weather.condition = conditions[Int(rng.next() % UInt64(conditions.count))]
                weather.windMPH = Double(rng.next() % 14)
                report.weather = weather

                if !isWeekend && slot == 1 {
                    report.focus = FocusState(label: "Work", isFocused: true)
                }

                // Health: steps climb through the day with a weekly rhythm;
                // gym visits add a workout + a big step delta (feeds insights).
                let baseSteps = isWeekend ? 3200.0 : 4600.0
                var steps = baseSteps + Double(slot) * 2900 + Double(rng.next() % 1500)
                var readings: [HealthReading] = []
                if isGymVisit {
                    steps += 3800
                    // 37 = HKWorkoutActivityType.running / 63 = traditional
                    // strength training — same "workout.<raw>" scheme as the
                    // real provider.
                    let workoutType = rng.next() % 2 == 0 ? 37 : 63
                    readings.append(HealthReading(
                        type: "workout.\(workoutType)", value: 2_100 + Double(rng.next() % 900),
                        unit: "s",
                        startDate: date.addingTimeInterval(-3600), endDate: date.addingTimeInterval(-600)
                    ))
                }
                readings.append(HealthReading(type: "steps", value: steps.rounded(), unit: "count",
                                              startDate: day, endDate: date))
                readings.append(HealthReading(type: "flightsClimbed",
                                              value: Double(rng.next() % 9), unit: "count"))
                readings.append(HealthReading(type: "heartRateAvg",
                                              value: 64 + Double(rng.next() % 22), unit: "bpm"))
                if slot > 0 {
                    readings.append(HealthReading(type: "caffeine",
                                                  value: Double(80 + Int(rng.next() % 90)), unit: "mg"))
                }
                if slot == reportsToday - 1 {
                    // Activity rings (same types the rings provider writes).
                    readings.append(HealthReading(type: "activity.move", value: 320 + Double(rng.next() % 260), unit: "kcal"))
                    readings.append(HealthReading(type: "activity.moveGoal", value: 500, unit: "kcal"))
                    readings.append(HealthReading(type: "activity.exercise", value: Double(rng.next() % 48), unit: "min"))
                    readings.append(HealthReading(type: "activity.exerciseGoal", value: 30, unit: "min"))
                    readings.append(HealthReading(type: "activity.stand", value: 6 + Double(rng.next() % 7), unit: "hr"))
                    readings.append(HealthReading(type: "activity.standGoal", value: 12, unit: "hr"))
                }
                report.health = readings

                context.insert(report)

                // Responses — the yes/no proportion band, token/people
                // frequency, and coffee-count graph all key off these.
                var responses: [Response] = []
                let working = !isWeekend && (slot == 0 || slot == 1) && place.name != "Gym"
                responses.append(answer(question("are-you-working"), options: [working ? "Yes" : "No"]))

                var doing = [activities[Int(rng.next() % UInt64(activities.count))]]
                if isGymVisit { doing = ["gym"] }
                if working, rng.next() % 2 == 0 { doing = ["coding", "meetings"] }
                responses.append(answer(question("what-are-you-doing"),
                                        tokens: doing.map { TokenValue(text: $0) }))

                var location = LocationAnswer()
                location.text = place.name
                location.location = snapshot
                responses.append(answer(question("where-are-you"), location: location))

                if rng.next() % 3 != 0 {
                    let who = people[Int(rng.next() % UInt64(people.count))]
                    responses.append(answer(question("who-are-you-with"),
                                            tokens: [TokenValue(text: who)]))
                } else {
                    responses.append(answer(question("who-are-you-with"), tokens: []))
                }

                // Coffee count: rises through the day, deterministic trend line.
                let coffees = slot == 0 ? Int(rng.next() % 2) : min(3, slot + Int(rng.next() % 2))
                responses.append(answer(question("how-many-coffees"), numeric: "\(coffees)"))

                if slot == reportsToday - 1, dayOffset % 3 == 0 {
                    responses.append(answer(question("what-did-you-learn"),
                                            text: lessons[Int(rng.next() % UInt64(lessons.count))]))
                }

                for response in responses {
                    context.insert(response)
                    response.report = report
                }
                reportIndex += 1
            }
        }

        // Prompt groups for the editor screenshot: one timed, one event-driven.
        let workday = PromptGroup()
        workday.uniqueIdentifier = "demo-group-workday"
        workday.name = "Workday check-in"
        workday.questionIDs = [question("are-you-working"), question("what-are-you-doing")]
            .compactMap { $0?.uniqueIdentifier }
        workday.schedule = .timesPerDay(count: 3, distribution: .semiRandom)
        workday.sortOrder = 0
        context.insert(workday)

        let postWorkout = PromptGroup()
        postWorkout.uniqueIdentifier = "demo-group-post-workout"
        postWorkout.name = "Post-workout"
        postWorkout.questionIDs = [question("what-are-you-doing"), question("how-many-coffees")]
            .compactMap { $0?.uniqueIdentifier }
        postWorkout.schedule = .workoutEnd
        postWorkout.sortOrder = 1
        context.insert(postWorkout)

        try context.save()

        // Token/people autocomplete in the survey shot draws from vocabulary.
        try VocabularyBuilder.rebuild(in: context)
    }

    private static func answer(_ question: Question?,
                               options: [String]? = nil,
                               tokens: [TokenValue]? = nil,
                               location: LocationAnswer? = nil,
                               numeric: String? = nil,
                               text: String? = nil) -> Response {
        let response = Response()
        response.questionPrompt = question?.prompt ?? ""
        response.questionIdentifier = question?.uniqueIdentifier
        response.answeredOptions = options
        response.tokens = tokens
        response.locationResponse = location
        response.numericResponse = numeric
        if let text { response.textResponses = [TokenValue(text: text)] }
        return response
    }

    /// Deterministic linear congruential generator (Numerical Recipes
    /// constants) — screenshots must be reproducible run-to-run.
    private struct LCG {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
    }
}
