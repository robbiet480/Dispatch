import Foundation
import Testing
@testable import DispatchKit

@Test func negativeSpeedDegradesToNil() {
    #expect(MotionFormatting.validSpeed(-1) == nil)
    #expect(MotionFormatting.validSpeed(0) == 0)
    #expect(MotionFormatting.validSpeed(5.5) == 5.5)
}

@Test func negativeCourseDegradesToNil() {
    #expect(MotionFormatting.validCourse(-1) == nil)
    #expect(MotionFormatting.validCourse(0) == 0)
    #expect(MotionFormatting.validCourse(270) == 270)
}

@Test func mphConversionMatchesKnownFactor() {
    let mph = MotionFormatting.mph(fromMPS: 10)
    #expect(abs(mph - 22.369362920544) < 0.0000001)
}

@Test func compassPointResolvesCardinalDirections() {
    #expect(MotionFormatting.compassPoint(forDegrees: 0) == "N")
    #expect(MotionFormatting.compassPoint(forDegrees: 90) == "E")
    #expect(MotionFormatting.compassPoint(forDegrees: 180) == "S")
    #expect(MotionFormatting.compassPoint(forDegrees: 270) == "W")
    // Wraparound: just past 348.75 rounds back to N (index 16 % 16 == 0).
    #expect(MotionFormatting.compassPoint(forDegrees: 359) == "N")
}
