import Foundation
import Testing
@testable import DispatchKit

private func reading(_ type: String, _ value: Double, _ unit: String = "") -> HealthReading {
    HealthReading(type: type, value: value, unit: unit)
}

// MARK: - Activity rings

@Test func activityRingsSummaryFormatsAllThreeRings() {
    let readings = [
        reading("activity.move", 320, "kcal"), reading("activity.moveGoal", 500, "kcal"),
        reading("activity.exercise", 22, "min"), reading("activity.exerciseGoal", 30, "min"),
        reading("activity.stand", 9, "count"), reading("activity.standGoal", 12, "count"),
    ]
    #expect(ActivityRingsFormatter.summary(from: readings)
        == "Move 320/500 · Exercise 22/30 · Stand 9/12")
}

@Test func activityRingsSummaryOmitsMissingRingsAndZeroGoals() {
    #expect(ActivityRingsFormatter.summary(from: [
        reading("activity.move", 320), reading("activity.moveGoal", 0),
    ]) == "Move 320")
    #expect(ActivityRingsFormatter.summary(from: [
        reading("activity.exercise", 22), reading("activity.exerciseGoal", 30),
    ]) == "Exercise 22/30")
    #expect(ActivityRingsFormatter.summary(from: [reading("steps", 100)]) == nil)
    #expect(ActivityRingsFormatter.summary(from: []) == nil)
}

@Test func activityRingsChecklistLine() {
    let readings = [
        reading("activity.move", 320.4, "kcal"), reading("activity.moveGoal", 500, "kcal"),
    ]
    #expect(ActivityRingsFormatter.checklistLine(from: readings) == "MOVE 320/500 KCAL")
    #expect(ActivityRingsFormatter.checklistLine(from: [reading("activity.move", 320)])
        == "MOVE 320 KCAL")
    #expect(ActivityRingsFormatter.checklistLine(from: []) == nil)
}

// MARK: - Triggered workout summary

@Test func triggeredWorkoutLineWithAllMetrics() {
    let readings = [
        reading("workout.trigger.type", 37), // Running
        reading("workout.trigger.duration", 32 * 60 + 10, "s"),
        reading("workout.trigger.energy", 412.3, "kcal"),
        reading("workout.trigger.distance", 5200, "m"),
        reading("workout.trigger.avgHeartRate", 148.2, "bpm"),
    ]
    #expect(TriggeredWorkoutSummary.line(from: readings)
        == "Running — 32m 10s · 412 kcal · 5.2 km · 148 bpm avg")
}

@Test func triggeredWorkoutLineOmitsAbsentMetrics() {
    let readings = [
        reading("workout.trigger.type", 57), // Yoga
        reading("workout.trigger.duration", 15 * 60, "s"),
    ]
    #expect(TriggeredWorkoutSummary.line(from: readings) == "Yoga — 15m 0s")
    // Type alone still names the workout.
    #expect(TriggeredWorkoutSummary.line(from: [reading("workout.trigger.type", 46)]) == "Swimming")
}

@Test func triggeredWorkoutLineNilWithoutTypeReading() {
    #expect(TriggeredWorkoutSummary.line(from: [
        reading("workout.trigger.duration", 600, "s"),
        reading("workout.37", 600, "s"),
    ]) == nil)
    #expect(TriggeredWorkoutSummary.line(from: []) == nil)
}

/// The trigger readings must not collide with the `workout.<raw>` display
/// mapping used for the today-workouts rows.
@Test func triggerReadingsDontParseAsWorkoutRows() {
    #expect(WorkoutActivityName.displayName(forHealthType: "workout.trigger.type") == nil)
    #expect(WorkoutActivityName.displayName(forHealthType: "workout.trigger.duration") == nil)
    #expect(WorkoutActivityName.displayName(forHealthType: "workout.37") == "Running")
}
