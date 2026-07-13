import XCTest
@testable import DispatchKit

@MainActor
final class PaneNavigationTests: XCTestCase {
    func testShowManagementPaneClearsReportSelection() {
        let nav = PaneNavigation()
        nav.selectedReportID = "r1"
        nav.show(.questions)
        XCTAssertEqual(nav.pane, .questions)
        XCTAssertNil(nav.selectedReportID)
    }

    func testOnlyDashboardShowsReportsSidebar() {
        XCTAssertTrue(AppPane.dashboard.showsReportsSidebar)
        for pane in AppPane.allCases where pane != .dashboard {
            XCTAssertFalse(pane.showsReportsSidebar)
        }
    }

    func testManagementFlag() {
        XCTAssertFalse(AppPane.dashboard.isManagement)
        XCTAssertFalse(AppPane.insights.isManagement)
        XCTAssertTrue(AppPane.questions.isManagement)
        XCTAssertTrue(AppPane.groups.isManagement)
        XCTAssertTrue(AppPane.catalog.isManagement)
    }
}
