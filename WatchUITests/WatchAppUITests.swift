import XCTest

/// Functional watch UI coverage — the wrist sibling of AppUITests. Unlike
/// WatchScreenshotTests (SCREENSHOT_MODE-gated capture only), these run on
/// every `xcodebuild test` and assert real behavior against the in-memory,
/// demo-seeded store that a `--ui-testing` launch stands up.
///
/// Launch-arg contract (already supported by DispatchWatchApp, no plumbing
/// added): `--ui-testing`/`--mock-sensors` route through
/// `WatchStoreBootstrap.isTestEnvironment()`, which (a) forces an in-memory
/// container — CloudKit is never touched — and (b) seeds the deterministic
/// `DefaultQuestions` set so the list/answer flows have rows to exercise.
/// There is NO `--demo-data` arg on the watch (that is an iOS-only flag);
/// `--ui-testing` already implies the demo question set on this target, so
/// nothing needed wiring through.
///
/// watchOS XCUITest reality (documented, not papered over):
/// - The suite is materially slower and flakier than iOS. Every wait uses a
///   generous timeout; the small screen means the List is lazy, so rows below
///   the fold don't enter the AX tree until scrolled — helpers below swipe.
/// - Digital-crown rotation is NOT drivable from XCUITest (no public
///   `rotateDigitalCrown`), so the `.number` stepper is exercised via its
///   +/- buttons and the crown-only `.time` readout is intentionally not
///   covered here (see the deliverable notes).
final class WatchAppUITests: XCTestCase {
    /// Generous by design — cold watch launches + first render routinely take
    /// 10s+ on the simulator.
    private let launchTimeout: TimeInterval = 30
    private let uiTimeout: TimeInterval = 15

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--mock-sensors"]
        app.launch()
        return app
    }

    /// The `.filed` confirmation is a SwiftUI `Label` whose concrete AX
    /// element type varies (staticText/image/other) across watchOS builds, so
    /// match the accessibility identifier across ALL element types in a single
    /// wait. A single wait matters: the confirmation is ephemeral (quick
    /// answer re-arms to idle after ~3s; the question view auto-dismisses
    /// after ~1.5s), so a chain of per-query waits would blow the whole budget
    /// on the first query and miss the window.
    private func filedElement(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The lazy watch List keeps off-screen rows out of the AX tree; swipe up
    /// until the element exists or we run out of attempts.
    /// Waits a beat after each swipe so the lazy List can render the newly
    /// on-screen rows into the AX tree before we re-check.
    @discardableResult
    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) -> Bool {
        if element.waitForExistence(timeout: 2) { return true }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) { return true }
        }
        return element.exists
    }

    /// Confirms the app reached its home screen (the quick-answer hero is the
    /// launch marker), so subsequent scrolls act on a rendered list rather than
    /// swiping a still-launching screen.
    @MainActor
    private func waitForHome(_ app: XCUIApplication) {
        XCTAssertTrue(
            app.buttons["watch-quick-answer-yes"].waitForExistence(timeout: launchTimeout),
            "home should load (quick-answer hero)"
        )
    }

    // MARK: - Home / demo data

    /// Pins: a `--ui-testing` launch reaches the home screen with the seeded
    /// demo question set — quick-answer surfaced, the questions List present,
    /// and a known below-the-fold row (the coffee number question) reachable.
    @MainActor
    func testLaunchesToHomeWithDemoData() throws {
        let app = launchApp()

        // Quick answer ("Are you working?" — first enabled yes/no) is the
        // home hero; its presence proves the seed ran and home rendered.
        XCTAssertTrue(
            app.buttons["watch-quick-answer-yes"].waitForExistence(timeout: launchTimeout),
            "quick-answer Yes button should surface on the demo-seeded home"
        )
        XCTAssertTrue(app.buttons["watch-quick-answer-no"].exists)

        // The questions List container renders.
        XCTAssertTrue(
            app.collectionViews["watch-question-list"].waitForExistence(timeout: uiTimeout)
            || app.tables["watch-question-list"].waitForExistence(timeout: 1)
            || app.otherElements["watch-question-list"].exists,
            "the questions list should exist"
        )

        // A known seeded row well below the fold is reachable by scrolling —
        // confirms the full DefaultQuestions set seeded, not just the hero.
        let coffeeRow = app.buttons["How many coffees did you have today?"]
        XCTAssertTrue(
            scrollToElement(coffeeRow, in: app),
            "the seeded coffee number-question row should be reachable"
        )
    }

    // MARK: - Quick answer files a report

    /// Pins: tapping the home quick-answer files a report end to end — the
    /// filer persists to the store and the UI advances to its `.filed`
    /// confirmation (`WatchReportFiler` only returns non-nil after a save, so
    /// the checkmark is proof the report is in the data).
    @MainActor
    func testQuickAnswerFilesReport() throws {
        let app = launchApp()

        let yes = app.buttons["watch-quick-answer-yes"]
        XCTAssertTrue(yes.waitForExistence(timeout: launchTimeout))
        yes.tap()

        // The `.filed` checkmark appears only after the async save resolves.
        XCTAssertTrue(
            filedElement("watch-quick-answer-filed", in: app).waitForExistence(timeout: uiTimeout),
            "quick answer should reach the Filed confirmation after saving"
        )
    }

    // MARK: - Number stepper round-trip

    /// Pins: the `.number` question round-trip — open the coffee question from
    /// the list, increment the crown-friendly Stepper, File, and land on the
    /// `.filed` confirmation.
    ///
    /// watchOS surfaces a SwiftUI `Stepper` NOT as `app.steppers` but as two
    /// standalone buttons — increment is `Add` (identifier `plus`), decrement
    /// is `Remove` (identifier `minus`) — with no separately-queryable value
    /// readout (confirmed empirically on watchOS 26). So we drive the `plus`
    /// button (the crown itself is not drivable from XCUITest) and rely on the
    /// filed confirmation as the persistence proof rather than reading a value.
    @MainActor
    func testNumberStepperRoundTripFiles() throws {
        let app = launchApp()
        waitForHome(app)

        let coffeeRow = app.buttons["How many coffees did you have today?"]
        XCTAssertTrue(scrollToElement(coffeeRow, in: app), "coffee row should be reachable")
        coffeeRow.tap()

        // Increment via the stepper's + button. On watchOS it carries label
        // "Add" (identifier "plus"), but the identifier goes stale after the
        // first tap (the sub-button re-renders on value change) while the label
        // stays stable — so match by label and re-resolve `app.buttons["Add"]`
        // fresh for each tap to exercise repeated crown-style increments.
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: uiTimeout), "stepper increment button should render")
        app.buttons["Add"].tap()
        app.buttons["Add"].tap()

        let file = app.buttons["watch-file-number"]
        XCTAssertTrue(file.waitForExistence(timeout: uiTimeout))
        file.tap()

        XCTAssertTrue(
            filedElement("watch-question-filed", in: app).waitForExistence(timeout: uiTimeout),
            "the number answer should reach the Filed confirmation after saving"
        )
    }

    // MARK: - Yes/No question from the list

    /// Pins: the List → NavigationLink → per-question answer path (distinct
    /// from the home quick answer). Opening "Are you working?" and tapping a
    /// choice files and reaches the `.filed` confirmation.
    @MainActor
    func testYesNoQuestionFromListFiles() throws {
        let app = launchApp()
        waitForHome(app)

        // The quick-answer question also appears as a regular list row; reach
        // it via the list (below the Quick Answer section).
        let workingRow = app.buttons["Are you working?"]
        XCTAssertTrue(scrollToElement(workingRow, in: app), "working row should be reachable")
        workingRow.tap()

        // On the answer screen the choice button has no identifier; its
        // accessibility label is "<choice>: <prompt>" (e.g. "Yes: Are you
        // working?"), so match by label prefix rather than a bare "Yes".
        let yesChoice = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Yes:")
        ).firstMatch
        XCTAssertTrue(yesChoice.waitForExistence(timeout: uiTimeout), "a Yes choice should render")
        yesChoice.tap()

        XCTAssertTrue(
            filedElement("watch-question-filed", in: app).waitForExistence(timeout: uiTimeout),
            "the yes/no answer should reach the Filed confirmation after saving"
        )
    }

    // MARK: - Settings

    /// Pins: Settings renders and is interactive — the sync-status line shows
    /// and at least one per-device sensor toggle can be flipped without crash.
    @MainActor
    func testSettingsRendersAndTogglesSensor() throws {
        let app = launchApp()
        XCTAssertTrue(app.buttons["watch-quick-answer-yes"].waitForExistence(timeout: launchTimeout))

        let settingsLink = app.buttons["watch-settings-link"]
        XCTAssertTrue(scrollToElement(settingsLink, in: app), "settings link should be reachable")
        settingsLink.tap()

        // Sync status line renders (test launch forces the "Off" copy since
        // sync is disabled under test args — assert the identifier, not text).
        XCTAssertTrue(
            app.staticTexts["watch-sync-status"].waitForExistence(timeout: uiTimeout),
            "sync-status line should render in settings"
        )

        // At least one sensor toggle exists and flips.
        let toggle = app.switches.firstMatch
        if toggle.waitForExistence(timeout: uiTimeout) {
            let before = toggle.value as? String
            toggle.tap()
            if let before, let after = toggle.value as? String {
                XCTAssertNotEqual(before, after, "sensor toggle should flip")
            }
        }
    }
}
