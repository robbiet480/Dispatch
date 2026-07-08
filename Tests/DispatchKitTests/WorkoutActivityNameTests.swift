import Foundation
import Testing
@testable import DispatchKit

@Suite("WorkoutActivityName")
struct WorkoutActivityNameTests {
    @Test("known raw values map to their SDK-documented names")
    func knownRawValues() {
        #expect(WorkoutActivityName.displayName(forRawValue: 13) == "Cycling")
        #expect(WorkoutActivityName.displayName(forRawValue: 37) == "Running")
        #expect(WorkoutActivityName.displayName(forRawValue: 52) == "Walking")
        #expect(WorkoutActivityName.displayName(forRawValue: 50) == "Traditional Strength Training")
        #expect(WorkoutActivityName.displayName(forRawValue: 20) == "Functional Strength Training")
        #expect(WorkoutActivityName.displayName(forRawValue: 46) == "Swimming")
        #expect(WorkoutActivityName.displayName(forRawValue: 82) == "Swim Bike Run")
        #expect(WorkoutActivityName.displayName(forRawValue: 3000) == "Other")
    }

    @Test("unknown raw value falls back to Workout (<raw>)")
    func unknownRawValueFallback() {
        #expect(WorkoutActivityName.displayName(forRawValue: 9999) == "Workout (9999)")
        #expect(WorkoutActivityName.displayName(forRawValue: 0) == "Workout (0)")
        #expect(WorkoutActivityName.displayName(forRawValue: 81) == "Workout (81)")
    }

    @Test("parses workout.<raw> health type strings")
    func parsesHealthTypeString() {
        #expect(WorkoutActivityName.displayName(forHealthType: "workout.37") == "Running")
        #expect(WorkoutActivityName.displayName(forHealthType: "workout.13") == "Cycling")
        #expect(WorkoutActivityName.displayName(forHealthType: "workout.9999") == "Workout (9999)")
    }

    @Test("non-workout health type strings return nil")
    func nonWorkoutTypeReturnsNil() {
        #expect(WorkoutActivityName.displayName(forHealthType: "steps") == nil)
        #expect(WorkoutActivityName.displayName(forHealthType: "flightsClimbed") == nil)
        #expect(WorkoutActivityName.displayName(forHealthType: "workout.") == nil)
        #expect(WorkoutActivityName.displayName(forHealthType: "workout.abc") == nil)
    }
}
