import Foundation
import Testing
@testable import DispatchKit

@Test func asleepWithNewerWorkoutDoesNotPromptOrAdvanceMarker() throws {
    let marker = Date(timeIntervalSince1970: 1_000)
    let end = Date(timeIntervalSince1970: 2_000)

    let plan = WorkoutEndMarkerPlanner.plan(
        currentMarker: marker, newestEndDate: end, isAwake: false)

    // Regression for the swallowed-workout bug: while asleep the marker must
    // NOT advance, so the workout stays eligible on the next observer fire.
    #expect(plan.shouldPrompt == false)
    #expect(plan.newMarker == marker)
}

@Test func awakeWithNewerWorkoutPromptsAndAdvancesMarker() throws {
    let marker = Date(timeIntervalSince1970: 1_000)
    let end = Date(timeIntervalSince1970: 2_000)

    let plan = WorkoutEndMarkerPlanner.plan(
        currentMarker: marker, newestEndDate: end, isAwake: true)

    #expect(plan.shouldPrompt == true)
    #expect(plan.newMarker == end)
}

@Test func noWorkoutsDoesNotPromptAndKeepsMarker() throws {
    let marker = Date(timeIntervalSince1970: 1_000)

    let plan = WorkoutEndMarkerPlanner.plan(
        currentMarker: marker, newestEndDate: nil, isAwake: true)

    #expect(plan.shouldPrompt == false)
    #expect(plan.newMarker == marker)
}

@Test func asleepThenWakeMakesWorkoutEligibleOnSecondFire() throws {
    let marker = Date(timeIntervalSince1970: 1_000)
    let end = Date(timeIntervalSince1970: 2_000)

    // First fire: asleep — marker unchanged, no prompt.
    let asleepPlan = WorkoutEndMarkerPlanner.plan(
        currentMarker: marker, newestEndDate: end, isAwake: false)
    #expect(asleepPlan.shouldPrompt == false)
    #expect(asleepPlan.newMarker == marker)

    // Second fire after wake: the same workout is still past the (unchanged)
    // marker, so it now prompts and the marker advances.
    let awakePlan = WorkoutEndMarkerPlanner.plan(
        currentMarker: asleepPlan.newMarker, newestEndDate: end, isAwake: true)
    #expect(awakePlan.shouldPrompt == true)
    #expect(awakePlan.newMarker == end)
}

@Test func markerNeverMovesBackward() throws {
    let marker = Date(timeIntervalSince1970: 2_000)
    let olderEnd = Date(timeIntervalSince1970: 1_000)

    let plan = WorkoutEndMarkerPlanner.plan(
        currentMarker: marker, newestEndDate: olderEnd, isAwake: true)

    #expect(plan.shouldPrompt == true)
    #expect(plan.newMarker == marker)
}
