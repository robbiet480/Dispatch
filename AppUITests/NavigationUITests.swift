import XCTest

final class NavigationUITests: XCTestCase {
    @MainActor
    func testNavigationAndAwakeToggle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        // Reports list: open, assert, and navigate back.
        let reportsListButton = app.buttons["reports-list-button"]
        XCTAssertTrue(reportsListButton.waitForExistence(timeout: 10))
        reportsListButton.tap()

        XCTAssertTrue(
            app.otherElements["reports-list"].waitForExistence(timeout: 10)
                || app.collectionViews["reports-list"].waitForExistence(timeout: 10)
                || app.tables["reports-list"].waitForExistence(timeout: 10)
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Settings -> Questions: open, assert, and navigate back out.
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let questionsLink = app.buttons["questions-settings-link"]
        XCTAssertTrue(questionsLink.waitForExistence(timeout: 10))
        questionsLink.tap()

        XCTAssertTrue(
            app.otherElements["question-settings-list"].waitForExistence(timeout: 10)
                || app.collectionViews["question-settings-list"].waitForExistence(timeout: 10)
                || app.tables["question-settings-list"].waitForExistence(timeout: 10)
        )

        // Back out of Questions, then back out of Settings to Home.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Awake toggle: capture current state, tap it, expect the survey sheet, cancel it.
        let awakeToggle = app.buttons["awake-toggle"]
        XCTAssertTrue(awakeToggle.waitForExistence(timeout: 10))
        let beforeLabel = awakeToggle.label
        XCTAssertTrue(beforeLabel == "AWAKE" || beforeLabel == "ASLEEP")

        awakeToggle.tap()

        let surveyCancel = app.buttons["survey-cancel"]
        XCTAssertTrue(surveyCancel.waitForExistence(timeout: 10))
        surveyCancel.tap()

        // CANCEL must not silently dismiss: it presents a discard confirmation.
        // Positive assertions on the alert and its Discard action, then discard.
        let discardAlert = app.alerts["Are you sure you want to discard this report?"]
        XCTAssertTrue(discardAlert.waitForExistence(timeout: 10),
                      "expected the discard confirmation alert after tapping CANCEL")
        let discardButton = discardAlert.buttons["Discard"]
        XCTAssertTrue(discardButton.exists)
        XCTAssertTrue(discardAlert.buttons["Cancel"].exists)
        discardButton.tap()

        // Toggling is authoritative even though the follow-up survey was cancelled,
        // so the label should have flipped between AWAKE and ASLEEP.
        XCTAssertTrue(awakeToggle.waitForExistence(timeout: 10))
        XCTAssertNotEqual(awakeToggle.label, beforeLabel)
    }

    @MainActor
    func testVisualizationFilterHidesToggledOffQuestionsPage() throws {
        let app = XCUIApplication()
        // Home only shows visualization pages once at least one report exists. Seed the
        // curated demo fixture at launch (--demo-data) so reports — and their viz pages —
        // are present immediately, instead of driving a full survey to create one.
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding", "--demo-data"]
        app.launch()

        // Reports already exist from the demo seed, so the visualization pages (and filter
        // pill) should be visible. The demo fixture seeds the default "Are you working?"
        // question with answers, so its viz page is present.
        let filterButton = app.buttons["viz-filter-button"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 10))

        // The paged TabView only mounts the current (and maybe adjacent) page, so swipe
        // through the pages to confirm the default "Are you working?" question's prompt is
        // present somewhere before we hide it.
        let questionPrompt = "Are you working?"
        var foundBeforeHiding = false
        for _ in 0..<8 {
            if app.staticTexts[questionPrompt].exists {
                foundBeforeHiding = true
                break
            }
            app.swipeLeft()
        }
        XCTAssertTrue(foundBeforeHiding, "expected to find the \"\(questionPrompt)\" viz page before hiding it")

        filterButton.tap()

        XCTAssertTrue(
            app.otherElements["viz-filter-list"].waitForExistence(timeout: 10)
                || app.collectionViews["viz-filter-list"].waitForExistence(timeout: 10)
                || app.tables["viz-filter-list"].waitForExistence(timeout: 10)
        )

        // Each row exposes both a row-level Switch (whole-row accessibility container, carries
        // the label) and a nested inner Switch (the actual small UISwitch control) — tapping
        // the outer element's center doesn't reliably flip state, so drill into the inner one.
        let rowToggle = app.switches[questionPrompt]
        XCTAssertTrue(rowToggle.waitForExistence(timeout: 10))
        let innerToggle = rowToggle.switches.firstMatch
        XCTAssertTrue(innerToggle.waitForExistence(timeout: 10))
        let valueBefore = innerToggle.value as? String
        innerToggle.tap()
        let valueAfter = innerToggle.value as? String
        XCTAssertNotEqual(valueBefore, valueAfter, "toggle value should flip on tap (before=\(String(describing: valueBefore)) after=\(String(describing: valueAfter)))")

        app.navigationBars.buttons["Done"].tap()

        // The toggled-off question's page/prompt must no longer appear anywhere on Home, even
        // after swiping through every remaining page.
        XCTAssertFalse(app.staticTexts[questionPrompt].waitForExistence(timeout: 5))
        for _ in 0..<8 {
            XCTAssertFalse(app.staticTexts[questionPrompt].exists)
            app.swipeLeft()
        }
    }

    /// End-to-end group-editor plumbing: create a group, assign a question,
    /// pick a NON-default (calendar event-end) schedule with a title-contains
    /// match rule, save, and assert it lands in the list with its schedule
    /// label and NO needs-access hint. The calendar variant is the richest of
    /// the group-create flows (it also asserts the needs-access hint is absent
    /// under the full-access test posture), so it stands in for the collapsed
    /// plain 4×/day and visit-arrival variants.
    ///
    /// The per-schedule-type LABEL and MATCH-rule semantics are pinned by the
    /// DispatchKit unit suite — GroupPlannerTests (schedule planning/labels)
    /// and CalendarEventPlannerTests (calendar match rules) — so this UI test
    /// only needs to exercise the editor plumbing for one schedule type.
    @MainActor
    func testCreatePromptGroupWithScheduleAppearsInList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let groupsLink = app.buttons["prompt-groups-link"]
        XCTAssertTrue(groupsLink.waitForExistence(timeout: 10))
        groupsLink.tap()

        let addButton = app.buttons["group-add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        var scrollsRemaining = 8
        while !addButton.isHittable, scrollsRemaining > 0 {
            app.swipeUp()
            scrollsRemaining -= 1
        }
        addButton.tap()

        let groupName = "Meetings \(Int(Date().timeIntervalSince1970) % 100_000)"
        addTeardownBlock { @MainActor in
            let row = app.staticTexts[groupName.uppercased()]
            guard row.exists else { return }
            row.swipeLeft()
            let deleteButton = app.buttons["Delete"]
            if deleteButton.waitForExistence(timeout: 5) {
                deleteButton.tap()
            }
        }

        let nameField = app.textFields["group-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText(groupName)

        let questionRow = app.buttons["Are you working?"]
        XCTAssertTrue(questionRow.waitForExistence(timeout: 10))
        questionRow.tap()

        // Form pickers render as a menu: open it, choose the calendar schedule.
        let schedulePicker = app.buttons["group-schedule-kind"]
        XCTAssertTrue(schedulePicker.waitForExistence(timeout: 10))
        schedulePicker.tap()
        let calendarOption = app.buttons["When a calendar event ends"]
        XCTAssertTrue(calendarOption.waitForExistence(timeout: 10))
        calendarOption.tap()

        // Match rule: Title contains, with a filter. The test posture reads
        // as full access, so no authorization hint appears in the editor.
        let matchPicker = app.buttons["group-calendar-match"]
        XCTAssertTrue(matchPicker.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["group-calendar-needs-access"].exists)
        XCTAssertFalse(app.buttons["group-calendar-needs-access"].exists)
        matchPicker.tap()
        let titleOption = app.buttons["Title contains"]
        XCTAssertTrue(titleOption.waitForExistence(timeout: 10))
        titleOption.tap()

        let titleField = app.textFields["group-calendar-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.tap()
        titleField.typeText("standup")

        app.buttons["group-save"].tap()

        // Back on the list: the calendar group shows with its schedule label
        // and NO needs-access hint (full-access test posture).
        XCTAssertTrue(app.staticTexts[groupName.uppercased()].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["When a calendar event ends – 1 question"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["group-row-needs-calendar"].exists)
    }

    /// Plan 45 (#56): create a place-trigger group via the editor and assert
    /// it lands in the list with its schedule summary and NO needs-Always
    /// hint (under `--mock-sensors` the observer reads authorized). The
    /// direction/delay/cancel semantics and the summary formatting are pinned
    /// by the DispatchKit unit suite (MonitorTriggerEngineTests /
    /// PromptGroupTests), so this only exercises the editor plumbing for the
    /// place arm — the beacon arm is the same shared control set.
    @MainActor
    func testCreatePlaceTriggerGroupAppearsInList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let groupsLink = app.buttons["prompt-groups-link"]
        XCTAssertTrue(groupsLink.waitForExistence(timeout: 10))
        groupsLink.tap()

        let addButton = app.buttons["group-add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        var scrollsRemaining = 8
        while !addButton.isHittable, scrollsRemaining > 0 {
            app.swipeUp()
            scrollsRemaining -= 1
        }
        addButton.tap()

        let groupName = "Office \(Int(Date().timeIntervalSince1970) % 100_000)"
        addTeardownBlock { @MainActor in
            let row = app.staticTexts[groupName.uppercased()]
            guard row.exists else { return }
            row.swipeLeft()
            let deleteButton = app.buttons["Delete"]
            if deleteButton.waitForExistence(timeout: 5) {
                deleteButton.tap()
            }
        }

        let nameField = app.textFields["group-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText(groupName)

        let questionRow = app.buttons["Are you working?"]
        XCTAssertTrue(questionRow.waitForExistence(timeout: 10))
        questionRow.tap()

        let schedulePicker = app.buttons["group-schedule-kind"]
        XCTAssertTrue(schedulePicker.waitForExistence(timeout: 10))
        schedulePicker.tap()
        let placeOption = app.buttons["When I arrive at / leave a place"]
        XCTAssertTrue(placeOption.waitForExistence(timeout: 10))
        placeOption.tap()

        // Full-access (Always) test posture: no needs-Always hint in editor.
        // A valid coordinate is required for Save (guards the (0,0) fallback).
        let latitude = app.textFields["group-place-latitude"]
        XCTAssertTrue(latitude.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["group-monitor-needs-always"].exists)
        XCTAssertFalse(app.buttons["group-monitor-needs-always"].exists)
        latitude.tap()
        latitude.typeText("37.3349")
        app.textFields["group-place-longitude"].tap()
        app.textFields["group-place-longitude"].typeText("-122.009")
        let placeName = app.textFields["group-place-name"]
        placeName.tap()
        placeName.typeText("HQ")

        app.buttons["group-save"].tap()

        // Back on the list: the place group shows with its schedule summary
        // ("Arrive at HQ", immediate) and NO needs-Always hint.
        XCTAssertTrue(app.staticTexts[groupName.uppercased()].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Arrive at HQ – 1 question"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["group-row-needs-always"].exists)
    }
}
