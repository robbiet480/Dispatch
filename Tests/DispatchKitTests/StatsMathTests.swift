import Foundation
import Testing
@testable import DispatchKit

/// Every claim here is pinned to an EXTERNALLY computed reference value
/// (scipy 1.16 / statsmodels 0.14 output, cited beside each expectation) —
/// the statistics are verified against references, never trusted.
/// Default tolerance 1e-3 unless noted.

private func approx(_ value: Double, _ expected: Double, _ tolerance: Double = 1e-3) -> Bool {
    abs(value - expected) <= tolerance
}

// MARK: - mean / standardDeviation (moved verbatim from InsightsEngine)

@Test func meanOfValues() {
    #expect(StatsMath.mean([2, 4, 4, 4, 5, 5, 7, 9]) == 5.0)
}

@Test func populationStandardDeviation() {
    // numpy.std([2,4,4,4,5,5,7,9]) = 2.0 (population SD, divisor n)
    #expect(StatsMath.standardDeviation([2, 4, 4, 4, 5, 5, 7, 9]) == 2.0)
    #expect(StatsMath.standardDeviation([5]) == 0)
    #expect(StatsMath.standardDeviation([]) == 0)
}

// MARK: - Wilson score interval

@Test func wilsonInterval() {
    // statsmodels proportion_confint(8, 10, method='wilson')
    // → (0.4901624715366418, 0.9433178485456247)
    let interval = StatsMath.wilsonInterval(successes: 8, trials: 10, confidence: 0.95)
    #expect(approx(interval.lowerBound, 0.490))
    #expect(approx(interval.upperBound, 0.943))
}

@Test func wilsonIntervalDegenerateRatesStayInsideUnitRange() {
    // statsmodels: 0/10 → (0.0, 0.2775327998628893); 10/10 → (0.7224672001371106, 1.0)
    let zero = StatsMath.wilsonInterval(successes: 0, trials: 10, confidence: 0.95)
    #expect(zero.lowerBound == 0)
    #expect(approx(zero.upperBound, 0.2775))
    let full = StatsMath.wilsonInterval(successes: 10, trials: 10, confidence: 0.95)
    #expect(approx(full.lowerBound, 0.7225))
    #expect(full.upperBound == 1)
    #expect(zero.lowerBound <= zero.upperBound)
    #expect(full.lowerBound <= full.upperBound)
}

// MARK: - Newcombe difference of proportions (MOVER on Wilson bounds)

@Test func newcombeDifferenceInterval() {
    // MOVER combination of Wilson bounds (Newcombe 1998 method 10), scipy-
    // verified: 8/10 vs 2/10 → (0.16182356511495904, 0.8026820451433557).
    // NOTE: the plan doc quoted ≈(0.170, 0.808); the externally computed
    // reference is (0.162, 0.803) — the computed value wins (global
    // constraint: verify, don't trust).
    let interval = StatsMath.newcombeDifferenceInterval(
        successes1: 8, trials1: 10, successes2: 2, trials2: 10, confidence: 0.95)
    #expect(approx(interval.lowerBound, 0.1618))
    #expect(approx(interval.upperBound, 0.8027))
    // The interval always contains the point estimate (0.6).
    #expect(interval.contains(0.6))
}

@Test func newcombeIntervalContainsPointEstimateAtDegenerateRates() {
    // 10/10 vs 0/10: point estimate 1.0; Wald would collapse, Wilson/MOVER
    // must stay sane and contain it.
    let interval = StatsMath.newcombeDifferenceInterval(
        successes1: 10, trials1: 10, successes2: 0, trials2: 10, confidence: 0.95)
    #expect(interval.contains(1.0))
    #expect(interval.lowerBound >= -1 && interval.upperBound <= 1)
}

// MARK: - Two-proportion z test

@Test func twoProportionPValue() {
    // Pooled two-sided z: 8/10 vs 2/10 → z = 2.683281572999748,
    // p = 0.007290358091535554 (scipy norm.cdf).
    let p = StatsMath.twoProportionPValue(successes1: 8, trials1: 10,
                                          successes2: 2, trials2: 10)
    #expect(approx(p, 0.00729, 1e-4))
}

// MARK: - Welch's t

@Test func welchTIntervalAndPValue() {
    // scipy.stats.ttest_ind([1,2,3,4,5], [2,4,6,8,10], equal_var=False)
    // → t = -1.8973665961010275, df = 5.882352941176471,
    //   p = 0.10753119493062724, CI95 = (-6.887741643736974, 0.8877416437369741).
    // NOTE: the plan doc quoted t ≈ −1.512 / p ≈ 0.189 / CI ≈ (−8.01, 2.01)
    // for this fixture; those numbers do not reproduce — the scipy output
    // above is the pinned reference.
    let result = StatsMath.welch([1, 2, 3, 4, 5], [2, 4, 6, 8, 10], confidence: 0.95)
    #expect(approx(result.pValue, 0.10753, 1e-4))
    #expect(approx(result.interval.lowerBound, -6.8877))
    #expect(approx(result.interval.upperBound, 0.8877))
}

@Test func welchWithUnequalSampleSizes() {
    // scipy.stats.ttest_ind(a, b, equal_var=False) with n=10 vs n=12:
    // t = 24.399593743600036, df = 15.754227347728579, p ≈ 6.12e-14,
    // CI95 = (1.8275354795204257, 2.175797853812908).
    let a = [8.1, 7.9, 8.3, 8.0, 7.8, 8.2, 8.4, 7.7, 8.05, 8.15]
    let b = [6.0, 6.2, 5.9, 6.1, 6.3, 5.8, 6.05, 6.15, 5.95, 6.25, 6.1, 5.9]
    let result = StatsMath.welch(a, b, confidence: 0.95)
    #expect(result.pValue < 1e-10)
    #expect(approx(result.interval.lowerBound, 1.8275))
    #expect(approx(result.interval.upperBound, 2.1758))
}

// MARK: - Pearson r

@Test func pearsonPerfectCorrelation() {
    let up = [(1.0, 2.0), (2.0, 4.0), (3.0, 6.0), (4.0, 8.0)]
    #expect(approx(StatsMath.pearsonR(up), 1.0, 1e-9))
    let down = [(1.0, 8.0), (2.0, 6.0), (3.0, 4.0), (4.0, 2.0)]
    #expect(approx(StatsMath.pearsonR(down), -1.0, 1e-9))
}

@Test func pearsonMatchesSciPyOnFixedReferenceSet() {
    // x = 0..19, y = 2x + N(0,5) noise from numpy RandomState(42);
    // scipy.stats.pearsonr → r = 0.9198287236866147 (tolerance 1e-6).
    let y = [2.483571, 1.308678, 7.238443, 13.615149, 6.829233,
             8.829315, 19.896064, 17.837174, 13.652628, 20.7128,
             17.682912, 19.671351, 25.209811, 16.433599, 19.375411,
             27.188562, 26.935844, 35.571237, 31.45988, 30.938481]
    let pairs = y.enumerated().map { (Double($0.offset), $0.element) }
    #expect(approx(StatsMath.pearsonR(pairs), 0.9198287236866147, 1e-6))
}

// MARK: - Fisher z

@Test func fisherIntervalAndPValue() {
    // Fisher z for r = 0.5, n = 30: atanh(0.5) ± 1.96/√27 →
    // CI = (0.17043136511180015, 0.7289585563883555),
    // p = 0.0043134705706167065 (two-sided normal).
    // NOTE: the plan doc quoted CI ≈ (0.160, 0.741) / p ≈ 0.0049; the
    // computed reference above is pinned instead.
    let result = StatsMath.fisher(r: 0.5, count: 30, confidence: 0.95)
    #expect(approx(result.interval.lowerBound, 0.1704))
    #expect(approx(result.interval.upperBound, 0.7290))
    #expect(approx(result.pValue, 0.004313, 1e-4))
}

/// PR #40 (Copilot): a Pearson r nudged just past ±1 by floating-point error
/// must never produce an interval bound outside [-1, 1] — the degenerate
/// early-return has to clamp BOTH ends, or the out-of-range value propagates
/// into the UI copy and tier mapping.
@Test func fisherClampsDegenerateRIntoValidRange() {
    for r in [-1.0000001, -1.0, 1.0, 1.0000001] {
        let result = StatsMath.fisher(r: r, count: 30, confidence: 0.95)
        #expect(result.interval.lowerBound >= -1.0,
                "lower bound \(result.interval.lowerBound) escaped [-1,1] for r=\(r)")
        #expect(result.interval.upperBound <= 1.0,
                "upper bound \(result.interval.upperBound) escaped [-1,1] for r=\(r)")
        #expect(result.interval.lowerBound <= result.interval.upperBound)
    }
}

// MARK: - Benjamini–Hochberg

@Test func benjaminiHochbergOriginalPaperExample() {
    // Benjamini & Hochberg (1995) §4 example, q = 0.05: statsmodels
    // multipletests(method='fdr_bh') rejects exactly the first four.
    let ps = [0.0001, 0.0004, 0.0019, 0.0095, 0.0201, 0.0278, 0.0298,
              0.0344, 0.0459, 0.3240, 0.4262, 0.5719, 0.6528, 0.7590, 1.000]
    #expect(StatsMath.benjaminiHochberg(pValues: ps, q: 0.05) == [0, 1, 2, 3])
}

@Test func benjaminiHochbergMcDonaldExample() {
    // McDonald, Handbook of Biological Statistics ("dear enemy" data).
    // statsmodels fdr_bh: at q = 0.05 only the first survives; at q = 0.25
    // the step-up reaches index 6 (0.074 ≤ 7/15 × 0.25) so the first seven
    // are rejected. (The plan doc claimed the first four at q = 0.05 —
    // that does not reproduce; statsmodels is the pinned reference.)
    let ps = [0.001, 0.008, 0.039, 0.041, 0.042, 0.06, 0.074, 0.205, 0.212,
              0.216, 0.222, 0.251, 0.269, 0.275, 0.34]
    #expect(StatsMath.benjaminiHochberg(pValues: ps, q: 0.05) == [0])
    #expect(StatsMath.benjaminiHochberg(pValues: ps, q: 0.25) == [0, 1, 2, 3, 4, 5, 6])
}

@Test func benjaminiHochbergEdgeCases() {
    #expect(StatsMath.benjaminiHochberg(pValues: [], q: 0.05).isEmpty)
    #expect(StatsMath.benjaminiHochberg(pValues: [1.0, 1.0, 1.0], q: 0.05).isEmpty)
    // Unsorted input: rejection is by hypothesis index, not sorted position.
    let scattered = StatsMath.benjaminiHochberg(pValues: [0.9, 0.0001, 0.8], q: 0.05)
    #expect(scattered == [1])
}

@Test func benjaminiHochbergIsDeterministicUnderTies() {
    // Two identical p-values straddling the threshold: both reject or
    // neither, and repeated runs agree (stable sort by (p, index)).
    let ps = [0.01, 0.01, 0.9, 0.9]
    let first = StatsMath.benjaminiHochberg(pValues: ps, q: 0.05)
    let second = StatsMath.benjaminiHochberg(pValues: ps, q: 0.05)
    #expect(first == second)
    #expect(first == [0, 1])
}

// MARK: - CDFs

@Test func normalCDFReferencePoints() {
    // scipy.stats.norm.cdf: Φ(0) = 0.5, Φ(1.96) = 0.9750021048517795.
    #expect(StatsMath.normalCDF(0) == 0.5)
    #expect(approx(StatsMath.normalCDF(1.96), 0.97500, 1e-4))
    #expect(approx(StatsMath.normalCDF(-1.96), 0.02500, 1e-4))
}

@Test func studentTCDFReferencePoints() {
    // scipy.stats.t.cdf(2.0, 10) = 0.9633059826146299.
    #expect(approx(StatsMath.studentTCDF(2.0, df: 10), 0.96331, 1e-4))
    #expect(StatsMath.studentTCDF(0, df: 7) == 0.5)
    #expect(approx(StatsMath.studentTCDF(-2.0, df: 10), 1 - 0.96331, 1e-4))
}
