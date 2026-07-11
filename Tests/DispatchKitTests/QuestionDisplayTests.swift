import Foundation
import Testing
@testable import DispatchKit

@Test func everyQuestionTypeHasADisplayName() {
    for type in QuestionType.allCases {
        #expect(!type.displayName.isEmpty)
    }
}

@Test func everyReportKindHasADisplayName() {
    for kind in ReportKind.allCases {
        #expect(!kind.displayName.isEmpty)
    }
}

@Test func everyNumberInputStyleHasADisplayName() {
    for style in NumberInputStyle.allCases {
        #expect(!style.displayName.isEmpty)
    }
}

@Test func exposedConfigFieldsMatchesPlan41Table() {
    #expect(NumberInputStyle.textField.exposedConfigFields == (min: false, max: false, step: false))
    #expect(NumberInputStyle.slider.exposedConfigFields == (min: true, max: true, step: true))
    #expect(NumberInputStyle.stepper.exposedConfigFields == (min: true, max: true, step: true))
    #expect(NumberInputStyle.dial.exposedConfigFields == (min: true, max: true, step: true))
    #expect(NumberInputStyle.tapCounter.exposedConfigFields == (min: false, max: true, step: false))
    #expect(NumberInputStyle.scale.exposedConfigFields == (min: true, max: true, step: false))
}

@Test func parseConfigTextRejectsNonFiniteAndJunk() {
    #expect(NumberInputStyle.parseConfigText("") == nil)
    #expect(NumberInputStyle.parseConfigText("  ") == nil)
    #expect(NumberInputStyle.parseConfigText("inf") == nil)
    #expect(NumberInputStyle.parseConfigText("nan") == nil)
    #expect(NumberInputStyle.parseConfigText("abc") == nil)
    #expect(NumberInputStyle.parseConfigText("10") == 10)
    #expect(NumberInputStyle.parseConfigText(" 2.5 ") == 2.5)
    #expect(NumberInputStyle.parseConfigText("-3") == -3)
}

@Test func groupScheduleSummaryReadouts() {
    #expect(GroupSchedule.everyNHours(4).summary == "Every 4h")
    #expect(GroupSchedule.timesPerDay(count: 3, distribution: .semiRandom).summary == "3× per day")
    #expect(GroupSchedule.workoutEnd.summary == "When a workout ends")
    #expect(GroupSchedule.visitArrival.summary == "When I arrive somewhere")
    #expect(GroupSchedule.disabled.summary == "Unknown schedule")
    var comps = DateComponents(); comps.hour = 9; comps.minute = 30
    #expect(GroupSchedule.dailyAt([comps]).summary == "Daily at 09:30")
    #expect(GroupSchedule.dailyAt([]).summary == "Daily")
}
