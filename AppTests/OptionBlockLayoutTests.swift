import XCTest

/// PR #41 review: the stacked-block heights must never sum past the
/// container. Hostless unit bundle — OptionBlockLayout.swift is compiled
/// directly into this target (see project.yml).
final class OptionBlockLayoutTests: XCTestCase {
    private func total(_ heights: [Double], spacing: Double = 2) -> Double {
        heights.reduce(0, +) + spacing * Double(max(heights.count - 1, 0))
    }

    func testProportionalWhenNoMinimumBinds() {
        let heights = OptionBlockLayout.heights(shares: [0.5, 0.5], availableHeight: 402)
        XCTAssertEqual(heights, [200, 200])
        XCTAssertEqual(total(heights), 402, accuracy: 0.001)
    }

    func testReviewCaseMinimumsNeverOverflowContainer() {
        // The review's overflow case: naive math gives 430pt in a 400pt box.
        let heights = OptionBlockLayout.heights(shares: [0.85, 0.05, 0.05, 0.05], availableHeight: 400)
        XCTAssertEqual(total(heights), 400, accuracy: 0.001)
        for height in heights {
            XCTAssertGreaterThanOrEqual(height, 28)
        }
        // Dominant share still dominates after minimums are carved out.
        XCTAssertGreaterThan(heights[0], heights[1] * 5)
    }

    func testManySmallOptionsStillFitExactly() {
        let shares = Array(repeating: 0.1, count: 10)
        let heights = OptionBlockLayout.heights(shares: shares, availableHeight: 500)
        XCTAssertEqual(total(heights), 500, accuracy: 0.001)
        XCTAssertEqual(Set(heights.map { ($0 * 1000).rounded() }).count, 1, "equal shares → equal heights")
    }

    func testDegenerateTinyContainerEqualSplit() {
        // 4 blocks can't fit 28pt minimums in 60pt — equal split, no overflow.
        let heights = OptionBlockLayout.heights(shares: [0.7, 0.1, 0.1, 0.1], availableHeight: 60)
        XCTAssertEqual(total(heights), 60, accuracy: 0.001)
        XCTAssertEqual(Set(heights.map { ($0 * 1000).rounded() }).count, 1)
    }

    func testEmptyAndZeroShares() {
        XCTAssertEqual(OptionBlockLayout.heights(shares: [], availableHeight: 400), [])
        let zeros = OptionBlockLayout.heights(shares: [0, 0], availableHeight: 402)
        XCTAssertEqual(total(zeros), 402, accuracy: 0.001)
    }
}
