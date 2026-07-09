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
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        // Home only shows visualization pages once at least one report exists — reuse the
        // mock-sensor report-flow pattern from SurveyFlowUITests to create one first.
        let countLabel = app.staticTexts["report-count"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        let before = countLabel.label

        app.buttons["report-button"].tap()
        XCTAssertTrue(app.otherElements["survey-progress"].waitForExistence(timeout: 10)
                      || app.progressIndicators["survey-progress"].waitForExistence(timeout: 10))

        let next = app.buttons["survey-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        if app.buttons["Yes"].exists { app.buttons["Yes"].tap() }
        for _ in 0..<12 where next.label == "NEXT" {
            next.tap()
        }
        XCTAssertEqual(next.label, "DONE")
        next.tap()

        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        XCTAssertNotEqual(countLabel.label, before)

        // A report now exists, so the visualization pages (and filter pill) should be visible.
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

    @MainActor
    func testCreatePromptGroupWithQuestionAppearsInList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        // Settings → Prompt Groups.
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let groupsLink = app.buttons["prompt-groups-link"]
        XCTAssertTrue(groupsLink.waitForExistence(timeout: 10))
        groupsLink.tap()

        XCTAssertTrue(
            app.otherElements["prompt-groups"].waitForExistence(timeout: 10)
                || app.collectionViews["prompt-groups"].waitForExistence(timeout: 10)
                || app.tables["prompt-groups"].waitForExistence(timeout: 10)
        )
        // Add a group and assign one question. The store is in-memory per
        // launch under --ui-testing, but scroll to the add row anyway so the
        // test survives a long list (belt and braces).
        let addButton = app.buttons["group-add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        var scrollsRemaining = 8
        while !addButton.isHittable, scrollsRemaining > 0 {
            app.swipeUp()
            scrollsRemaining -= 1
        }
        XCTAssertTrue(addButton.isHittable, "ADD A GROUP row should be reachable by scrolling")
        addButton.tap()

        let groupName = "Check-in \(Int(Date().timeIntervalSince1970) % 100_000)"
        // Clean up the created group even if an assertion below fails, so a
        // failed run can't pollute the list for later tests in this launch.
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

        app.buttons["group-save"].tap()

        // Back on the list: the new group shows with its question count and
        // the empty-state explainer is gone.
        XCTAssertTrue(app.staticTexts[groupName.uppercased()].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["4× per day – 1 question"].exists)
        XCTAssertFalse(app.staticTexts["prompt-groups-empty"].exists)
    }

    /// Plan 16: a visit-arrival group can be created entirely through the
    /// editor under --mock-sensors (the observer and the Always-location
    /// request are test-gated — no system dialog) and lands in the list
    /// with its schedule label.
    @MainActor
    func testCreateVisitArrivalGroupShowsScheduleLabel() throws {
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

        let groupName = "Arrivals \(Int(Date().timeIntervalSince1970) % 100_000)"
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

        // Form pickers render as a menu: open it, choose the visit schedule.
        let schedulePicker = app.buttons["group-schedule-kind"]
        XCTAssertTrue(schedulePicker.waitForExistence(timeout: 10))
        schedulePicker.tap()
        let visitOption = app.buttons["When I arrive somewhere"]
        XCTAssertTrue(visitOption.waitForExistence(timeout: 10))
        visitOption.tap()

        app.buttons["group-save"].tap()

        // Back on the list: the visit group shows with its schedule label.
        XCTAssertTrue(app.staticTexts[groupName.uppercased()].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["When I arrive somewhere – 1 question"].waitForExistence(timeout: 10))
    }
}
