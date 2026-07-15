import XCTest
@testable import DispatchKit

/// Reproduces the "confirmation appears in two windows at once" bug: on the Mac
/// both the main window and the Settings scene observe the same export
/// controller, so a result message with no notion of origin lights up every
/// scene bound to it. `ResultMessageState` records WHICH scene asked, and only
/// that scene presents.
final class ResultMessageStateTests: XCTestCase {
    func testFreshStateIsNotPresentedAnywhere() {
        let state = ResultMessageState()
        XCTAssertFalse(state.isPresented(in: .primary))
        XCTAssertFalse(state.isPresented(in: .settings))
    }

    /// THE bug: a Settings-originated message must present in Settings and
    /// NOWHERE else. Before the fix both scenes shared one boolean, so this is
    /// exactly the assertion that would have caught the double alert.
    func testMessagePresentsOnlyInItsOriginScene() {
        var state = ResultMessageState()
        state.present("Exported reports.csv.", from: .settings)

        XCTAssertTrue(state.isPresented(in: .settings),
                      "the scene that triggered the export should show the confirmation")
        XCTAssertFalse(state.isPresented(in: .primary),
                       "the main window must NOT also show a Settings-triggered confirmation")
        XCTAssertEqual(state.text, "Exported reports.csv.")
    }

    func testPrimaryOriginPresentsOnlyInPrimary() {
        var state = ResultMessageState()
        state.present("Imported 3 reports.", from: .primary)

        XCTAssertTrue(state.isPresented(in: .primary))
        XCTAssertFalse(state.isPresented(in: .settings))
    }

    /// Dismissing (either scene's binding sets false) clears it everywhere, so
    /// the alert never lingers in the other window.
    func testDismissClearsPresentationInEveryScene() {
        var state = ResultMessageState()
        state.present("Exported.", from: .settings)
        state.dismiss()

        XCTAssertFalse(state.isPresented(in: .settings))
        XCTAssertFalse(state.isPresented(in: .primary))
    }

    /// A later message from a different scene re-targets cleanly — no stale
    /// origin leaves the previous scene showing.
    func testLatestOriginWins() {
        var state = ResultMessageState()
        state.present("From settings.", from: .settings)
        state.present("From menu.", from: .primary)

        XCTAssertTrue(state.isPresented(in: .primary))
        XCTAssertFalse(state.isPresented(in: .settings))
        XCTAssertEqual(state.text, "From menu.")
    }
}
