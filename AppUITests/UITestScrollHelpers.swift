import XCTest

extension XCUIApplication {
    /// Waits for `anchor` to exist, then swipes up (on the app) up to
    /// `maxSwipes` times until `target` is hittable — the shared "scroll the
    /// lazily-rendered settings row into view" idiom. SwiftUI's `List`
    /// materializes off-screen rows lazily, so a row below the fold isn't in the
    /// accessibility tree until scrolled near; the bounded loop stops early once
    /// `target.isHittable`. Callers keep their own post-scroll assertions
    /// (`target.waitForExistence`, `.tap()`, value checks).
    @MainActor
    func scrollUntilHittable(
        _ target: XCUIElement,
        anchoredOn anchor: XCUIElement,
        maxSwipes: Int = 8,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(anchor.waitForExistence(timeout: timeout), file: file, line: line)
        var swipes = 0
        while !target.isHittable, swipes < maxSwipes {
            swipeUp()
            swipes += 1
        }
    }
}
