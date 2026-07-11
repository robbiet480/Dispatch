import Foundation

/// Internal statistics primitives shared by InsightsEngine and
/// CorrelationEngine (plan 34). Pure, deterministic, dependency-free — every
/// method is closed-form (no resampling) and pinned to externally computed
/// reference values in StatsMathTests.
enum StatsMath {
    // MARK: - Moments (moved verbatim from InsightsEngine)

    static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    /// Population SD (divisor n) — moved VERBATIM from InsightsEngine.
    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let average = mean(values)
        let variance = values.reduce(0) { $0 + ($1 - average) * ($1 - average) }
            / Double(values.count)
        return variance.squareRoot()
    }

    // MARK: - Proportions

    /// Wilson score interval for a proportion. Well-behaved at 0% and 100%
    /// observed rates, where the Wald interval collapses to a point.
    static func wilsonInterval(successes: Int, trials: Int,
                               confidence: Double) -> ClosedRange<Double> {
        guard trials > 0 else { return 0...1 }
        let z = normalQuantile(1 - (1 - confidence) / 2)
        let n = Double(trials)
        let p = Double(successes) / n
        let z2 = z * z
        let denominator = 1 + z2 / n
        let center = p + z2 / (2 * n)
        let halfWidth = z * (p * (1 - p) / n + z2 / (4 * n * n)).squareRoot()
        let lower = max(0, (center - halfWidth) / denominator)
        let upper = min(1, (center + halfWidth) / denominator)
        return lower...upper
    }

    /// Newcombe MOVER difference-of-proportions interval for p1 − p2
    /// (Newcombe 1998, method 10): Wilson intervals per side, combined by
    /// the square-and-add method of variance estimates recovery.
    static func newcombeDifferenceInterval(successes1: Int, trials1: Int,
                                           successes2: Int, trials2: Int,
                                           confidence: Double) -> ClosedRange<Double> {
        guard trials1 > 0, trials2 > 0 else { return -1...1 }
        let p1 = Double(successes1) / Double(trials1)
        let p2 = Double(successes2) / Double(trials2)
        let w1 = wilsonInterval(successes: successes1, trials: trials1, confidence: confidence)
        let w2 = wilsonInterval(successes: successes2, trials: trials2, confidence: confidence)
        let delta = p1 - p2
        let lower = delta - ((p1 - w1.lowerBound) * (p1 - w1.lowerBound)
            + (w2.upperBound - p2) * (w2.upperBound - p2)).squareRoot()
        let upper = delta + ((w1.upperBound - p1) * (w1.upperBound - p1)
            + (p2 - w2.lowerBound) * (p2 - w2.lowerBound)).squareRoot()
        return max(-1, lower)...min(1, upper)
    }

    /// Two-proportion z-test p-value (two-sided, pooled standard error).
    static func twoProportionPValue(successes1: Int, trials1: Int,
                                    successes2: Int, trials2: Int) -> Double {
        guard trials1 > 0, trials2 > 0 else { return 1 }
        let n1 = Double(trials1), n2 = Double(trials2)
        let p1 = Double(successes1) / n1
        let p2 = Double(successes2) / n2
        let pooled = Double(successes1 + successes2) / (n1 + n2)
        let standardError = (pooled * (1 - pooled) * (1 / n1 + 1 / n2)).squareRoot()
        guard standardError > 0 else { return 1 }
        let z = (p1 - p2) / standardError
        return 2 * (1 - normalCDF(abs(z)))
    }

    // MARK: - Means (Welch's t)

    /// Welch's unequal-variances t: confidence interval and two-sided
    /// p-value for mean(a) − mean(b), df via Welch–Satterthwaite.
    static func welch(_ a: [Double], _ b: [Double], confidence: Double)
        -> (interval: ClosedRange<Double>, pValue: Double) {
        guard a.count > 1, b.count > 1 else { return (interval: 0...0, pValue: 1) }
        let n1 = Double(a.count), n2 = Double(b.count)
        let mean1 = mean(a), mean2 = mean(b)
        // Sample variances (divisor n−1), as Welch's statistic requires.
        let variance1 = a.reduce(0) { $0 + ($1 - mean1) * ($1 - mean1) } / (n1 - 1)
        let variance2 = b.reduce(0) { $0 + ($1 - mean2) * ($1 - mean2) } / (n2 - 1)
        let delta = mean1 - mean2
        let squaredError1 = variance1 / n1
        let squaredError2 = variance2 / n2
        let standardError = (squaredError1 + squaredError2).squareRoot()
        guard standardError > 0 else { return (interval: delta...delta, pValue: 1) }
        let df = (squaredError1 + squaredError2) * (squaredError1 + squaredError2)
            / (squaredError1 * squaredError1 / (n1 - 1)
               + squaredError2 * squaredError2 / (n2 - 1))
        let t = delta / standardError
        let pValue = 2 * (1 - studentTCDF(abs(t), df: df))
        let critical = studentTQuantile(1 - (1 - confidence) / 2, df: df)
        let interval = (delta - critical * standardError)...(delta + critical * standardError)
        return (interval: interval, pValue: pValue)
    }

    // MARK: - Correlation (Pearson + Fisher z)

    static func pearsonR(_ pairs: [(Double, Double)]) -> Double {
        guard pairs.count > 1 else { return 0 }
        let xs = pairs.map(\.0), ys = pairs.map(\.1)
        let meanX = mean(xs), meanY = mean(ys)
        var covariance = 0.0, varianceX = 0.0, varianceY = 0.0
        for (x, y) in pairs {
            covariance += (x - meanX) * (y - meanY)
            varianceX += (x - meanX) * (x - meanX)
            varianceY += (y - meanY) * (y - meanY)
        }
        let denominator = (varianceX * varianceY).squareRoot()
        guard denominator > 0 else { return 0 }
        return covariance / denominator
    }

    /// Fisher-z interval + two-sided p-value for a Pearson r at sample size n.
    static func fisher(r: Double, count: Int, confidence: Double)
        -> (interval: ClosedRange<Double>, pValue: Double) {
        guard count > 3, abs(r) < 1 else {
            return (interval: min(r, 1)...min(max(r, -1), 1), pValue: abs(r) >= 1 ? 0 : 1)
        }
        let z = atanh(r)
        let standardError = 1 / Double(count - 3).squareRoot()
        let critical = normalQuantile(1 - (1 - confidence) / 2)
        let lower = tanh(z - critical * standardError)
        let upper = tanh(z + critical * standardError)
        let pValue = 2 * (1 - normalCDF(abs(z / standardError)))
        return (interval: lower...upper, pValue: pValue)
    }

    // MARK: - Multiplicity (Benjamini–Hochberg)

    /// Benjamini–Hochberg step-up: indices of hypotheses rejected at false
    /// discovery rate `q`. Deterministic under ties — the sort is stable by
    /// (p, original index), and rejection is "everything at or below the
    /// largest k with p(k) ≤ k/m·q", so tied p-values share one fate.
    static func benjaminiHochberg(pValues: [Double], q: Double) -> Set<Int> {
        guard !pValues.isEmpty else { return [] }
        let m = Double(pValues.count)
        let ranked = pValues.enumerated()
            .sorted { lhs, rhs in
                if lhs.element != rhs.element { return lhs.element < rhs.element }
                return lhs.offset < rhs.offset
            }
        var cutoff = -1
        for (rank, entry) in ranked.enumerated()
        where entry.element <= Double(rank + 1) / m * q {
            cutoff = rank
        }
        guard cutoff >= 0 else { return [] }
        return Set(ranked[0...cutoff].map(\.offset))
    }

    // MARK: - Distributions

    /// Standard normal CDF via erfc (Darwin/Glibc).
    static func normalCDF(_ z: Double) -> Double {
        0.5 * erfc(-z / 2.0.squareRoot())
    }

    /// Standard normal quantile (inverse CDF) via bisection on `normalCDF`.
    /// Deterministic and plenty fast for the handful of calls per compute;
    /// accuracy far exceeds the 1e-3 test tolerance.
    static func normalQuantile(_ p: Double) -> Double {
        precondition(p > 0 && p < 1, "quantile requires 0 < p < 1")
        var low = -12.0, high = 12.0
        for _ in 0..<200 {
            let mid = (low + high) / 2
            if normalCDF(mid) < p { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// Student-t CDF via the regularized incomplete beta function:
    /// for t ≥ 0, CDF(t, ν) = 1 − ½·I_x(ν/2, ½) with x = ν/(ν + t²).
    static func studentTCDF(_ t: Double, df: Double) -> Double {
        guard df > 0 else { return 0.5 }
        if t == 0 { return 0.5 }
        let x = df / (df + t * t)
        let tail = 0.5 * regularizedIncompleteBeta(a: df / 2, b: 0.5, x: x)
        return t > 0 ? 1 - tail : tail
    }

    /// Student-t quantile via bisection on `studentTCDF` (monotone CDF).
    static func studentTQuantile(_ p: Double, df: Double) -> Double {
        precondition(p > 0 && p < 1, "quantile requires 0 < p < 1")
        var low = -1e6, high = 1e6
        for _ in 0..<200 {
            let mid = (low + high) / 2
            if studentTCDF(mid, df: df) < p { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    // MARK: - Incomplete beta (Numerical Recipes continued fraction)

    /// Regularized incomplete beta I_x(a, b), Numerical Recipes §6.4 form:
    /// the continued fraction `betacf` evaluated with the symmetry switch at
    /// x = (a+1)/(a+b+2) for convergence.
    private static func regularizedIncompleteBeta(a: Double, b: Double, x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        var logPrefix: Double = lgamma(a + b) - lgamma(a) - lgamma(b)
        logPrefix += a * log(x)
        logPrefix += b * log(1 - x)
        let prefix = exp(logPrefix)
        if x < (a + 1) / (a + b + 2) {
            return prefix * betaContinuedFraction(a: a, b: b, x: x) / a
        }
        return 1 - prefix * betaContinuedFraction(a: b, b: a, x: 1 - x) / b
    }

    /// Modified Lentz evaluation of the incomplete-beta continued fraction
    /// (Numerical Recipes `betacf`).
    private static func betaContinuedFraction(a: Double, b: Double, x: Double) -> Double {
        let tiny = 1e-30
        let epsilon = 1e-14
        let qab = a + b, qap = a + 1, qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        for m in 1...300 {
            let m2 = Double(2 * m)
            let md = Double(m)
            var aa = md * (b - md) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c
            aa = -(a + md) * (qab + md) * x / ((a + m2) * (qap + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < epsilon { break }
        }
        return h
    }
}
