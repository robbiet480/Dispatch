# Dispatch Plan 34: Correlation insights

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal (issue #19):** per-question correlation drill-ins — pick a question and see how its answers relate to every context dimension Dispatch already records (people present, sleep, steps, heart rate, places, connection type, time of day) — with STATISTICAL HONESTY as a hard constraint: documented minimum sample sizes, effect sizes with confidence intervals instead of bare "2× more likely" claims, explicit correlation-≠-causation copy, and nothing surfaced as a finding below threshold. Explicit nulls ("no reliable link") and explicit data gaps ("not enough data") render instead of silently hiding, so absence of a claim is itself information.

**Architecture:** a new pure-kit `CorrelationEngine` in `Sources/DispatchKit/Insights/` beside `InsightsEngine` — same input surface (`[Report]`, `[Question]`, `[PersonEntity]`), same all-reports-never-filtered decision, same deterministic-output discipline — but a different shape: `InsightsEngine` broadcasts the top-8 strongest associations across everything; `CorrelationEngine` answers "tell me about THIS question" exhaustively, one row per context dimension, each row a finding, an explicit null, or an insufficient-data marker. Shared math (mean/SD plus the new interval + p-value primitives) is factored into an internal `StatsMath` enum both engines use. No schema, model, or wire changes anywhere — correlations are recomputed on demand, never persisted. UI is a new CORRELATIONS section on the existing Insights screen with a per-question `NavigationLink` drill-in.

**Tech Stack:** pure Swift statistics (no dependencies): Newcombe score intervals for rate differences, Welch's t for mean differences, Fisher z for Pearson r, Benjamini–Hochberg for multiplicity; Swift Testing (`@Test`) with synthetic ground-truth fixtures; SwiftUI (`@Query`, memoized `.task(id:)` — the InsightsView pattern).

## Design decisions (decide + log)

- **Separate engine, not an InsightsEngine mode.** The two features have opposite output contracts: InsightsEngine is capped, cross-everything, silence-below-threshold-by-omission; CorrelationEngine is exhaustive over one question's dimension list with EXPLICIT null/insufficient rows. Bolting a per-question mode onto InsightsEngine would fork every guard with conditionals. InsightsEngine's behavior does not change in this plan (its tests pin that); the only refactor it sees is `mean`/`standardDeviation` moving to `StatsMath` verbatim.
- **Target question kinds (v1):** `yesNo` (binary target: the yes answer), `number` (numeric target — the "scale" answer kind; slider/stepper/keypad input styles all land in `numericResponse`), `multipleChoice` (one binary target PER CHOICE), `tokens` and `people` (one binary target per token/person, capped). `location` and `note` questions are not targets in v1 (no natural scalar/binary reading); if plan 28's `time` type has merged by implementation, it is ALSO out of scope v1 — record the integration point (circular statistics needed) in the completion note.
- **Context dimensions (v1) — one row each in the drill-in:**
  - **People** (plan 22): one binary dimension per registry-resolved person (`PersonResolver.person(matching:in:)`, alias → canonical, displayed by current name), presence from `people`-typed responses' tokens. Capped at the top 8 by presence count (id tiebreak).
  - **Places:** one binary dimension per place, grouped by Foursquare venue ID else text — the ReportsOverview/InsightsEngine convention — from `locationResponse` answers. Capped at top 8.
  - **Connection type:** one binary dimension per observed `ConnectionType` category, labeled by `displayName`. **Rebase-aware (PR #25 / plan 26 unmerged as of 2026-07-10):** if plan 26 has merged by implementation time, `ConnectionType.displayName` and raws 0–8 exist — use them directly. If not, implement a private `label(forConnectionRaw:)` table in CorrelationEngine carrying plan 26's exact taxonomy (0 Cellular, 1 Wi-Fi, 2 None, 3 Wired, 4 5G, 5 LTE, 6 3G, 7 2G, 8 Satellite) with a `// TODO(plan-26 rebase): replace with ConnectionType.displayName` marker, and group by raw int — unknown raws are excluded (consistent with `Report.connectionType` returning nil for unknowns). Old coarse values and new granular values coexist as distinct categories forever (no reinterpretation — the plan 26 freeze); the drill-in row copy says "on Wi-Fi" / "on LTE" per category.
  - **Time of day:** four binary dimensions — Morning 05:00–11:59, Afternoon 12:00–16:59, Evening 17:00–21:59, Night 22:00–04:59 — computed from `report.date` **in the report's own `timeZoneIdentifier`** (wall-clock honesty: a 9 AM report filed in Tokyo is Morning, whatever the phone's current zone). Every filed report is eligible; exactly one bucket is present per report.
  - **Sleep** (numeric, hours): sum of the report's `HealthReading`s whose `type` has prefix `"sleep"` (`sleepDeep`/`sleepREM`/`sleepCore`/`sleepUnspecified`, unit seconds — `HealthProviders.sleepSeconds`) ÷ 3600. Defined ONLY for reports that carry at least one sleep reading — a report without sleep readings is missing data, not a zero-hour night (the workoutMinutes precedent in InsightsEngine).
  - **Steps** (numeric): sum of `"steps"` readings, defined only when present.
  - **Heart rate** (numeric ×2): `"heartRateAvg"` (bpm) and `"restingHeartRate"` (bpm), each its own dimension, defined only when present. (`hrvSDNN` deliberately deferred — ms-scale HRV needs its own literacy copy; log as follow-up.)
- **Method by target × dimension type** (all closed-form, deterministic, no resampling):
  - binary target × binary dimension → **rate difference** P(target | in) − P(target | out), 95% CI via **Newcombe's score-interval difference method** (Wilson intervals per side, MOVER combination) — behaves correctly at 0%/100% rates where the Wald interval collapses. p-value from the two-proportion z test.
  - binary target × numeric dimension → **difference of means** of the numeric between target-yes and target-no reports; effect size = standardized mean difference **d = |Δ| / combined-sample SD** (the InsightsEngine convention — both sides pooled into ONE sample, conservative); 95% CI and p-value via **Welch's t** (unequal variances, Welch–Satterthwaite df).
  - numeric target × binary dimension → difference of means of the ANSWER in/out of the dimension — same Welch machinery, roles swapped.
  - numeric target × numeric dimension → **Pearson r** over reports where both are defined; 95% CI and p-value via the **Fisher z transform**. This is the only pair that is a "correlation coefficient" in the textbook sense; everything else reports differences — the copy layer never says "correlation of 0.4" for a rate difference.
- **THE HONESTY GUARDS (documented thresholds — public `static let`s on CorrelationEngine so tests and docs cite one source of truth):**
  - `minimumSideCount = 10` — reports on EACH side of every binary split (matches InsightsEngine).
  - `minimumPairCount = 20` — jointly-defined reports for numeric×numeric Pearson.
  - `minimumEligibleAnswers = 20` — answered filed reports before a question is drill-in eligible at all (2 × minimumSideCount).
  - Effect floors (below floor → explicit null, never a finding): `minimumRateDelta = 0.15` absolute rate difference; `minimumStandardizedDifference = 0.35` (between Cohen's small 0.2 and medium 0.5 — the drill-in may show slightly weaker effects than the top-8 feed's 0.5 because every finding carries its interval and sample count on screen); `minimumPearsonR = 0.30`.
  - **Multiplicity control:** within one question's drill-in, all computed p-values pass through **Benjamini–Hochberg at q = 0.05**; only BH-significant comparisons can become findings. A drill-in tests ~25–30 dimensions — uncorrected 95% gating would manufacture ≈1.5 false findings per question, which is exactly the dishonesty this plan exists to prevent. BH is deterministic, closed-form, and testable (a fixture with one planted effect among many noise dimensions must surface exactly the planted one).
  - A finding therefore requires ALL of: side/pair minimums met, BH-significant, effect ≥ floor. Otherwise the row is `noReliableLink(sampleCount:)` (tested, nothing held up) when minimums were met, or `insufficientData(have:needed:)` when they weren't. **No correlation is ever surfaced below threshold — and no threshold failure is ever silent.**
  - Effect tiers for display: standardized difference 0.35/0.5/0.8 and |r| 0.3/0.5/0.7 and rate delta 0.15/0.25/0.40 map to **weak / moderate / strong** — qualitative word next to the real numbers, never instead of them.
- **Language contract (extends the Insight contract):** headline `"You answered Yes more often when Angela was around."`; detail always carries both sides + interval + n: `"Yes on 72% of 25 reports with Angela vs 41% of 34 without — a 31-point difference (95% CI 8 to 52)."` Banned phrasings, pinned by test: `"2x"`, `"twice as likely"`, `"causes"`, `"because of"`, `"leads to"`, `"makes you"`, `"proves"`. Every drill-in renders the standing footer copy (kit constant so digest/exports reuse it verbatim): `"These are correlations in your own history, not causes. Filing patterns, seasons, and habits all move together — no comparison here can say which drives which."`
- **Missing data never masquerades as absence** (the InsightsEngine eligibility discipline, reused): person/place dimensions are eligible only on reports where the OWNING question(s) were answered; the target question's side counts come only from reports where IT was answered; health dimensions only from reports carrying that reading. The universe for any single comparison is the intersection of target-eligible and dimension-eligible reports.
- **Self-pairing exclusion:** a question never correlates against a dimension derived from itself — a people-question target skips any person dimension whose owners include that question; state-of-mind questions reuse InsightsEngine's `sourceKey` "mood" convention if a mood-derived dimension is ever added. Restating the identity function is not a finding.
- **Always all filed reports, never the visualization filter subset** — same logged decision as InsightsEngine, same reason: filtering first invites spurious conclusions from tiny subsets, defeating the sample-size guards.
- **Compute placement:** pure synchronous kit function, memoized in the view with the `.task(id:)` fingerprint pattern (InsightsView precedent). Per-question compute is O(reports × dimensions) over in-memory sets — the InsightsEngine performance envelope; no actor hop needed (@Model non-Sendable, same trade).
- **Multi-target rendering (multipleChoice/tokens/people questions):** the drill-in groups rows by target ("When you answered *Red*…", "When you mentioned *coffee*…"), targets capped at the top 8 by answer count (label tiebreak) with an honest "showing your 8 most common answers" caption when capped. yesNo and number questions have exactly one target.
- **Digest/InsightsEngine integration explicitly out of scope v1:** the top-8 feed and weekly digest keep their existing engine; a follow-up may promote strong per-question findings into the feed. Log in the completion note.

## Global Constraints

- Kit changes test-first: failing test → `swift test` red → implement → `swift test` green, per task. App target verified with `xcodebuild build-for-testing` (UI suite reserved for the merge gate).
- **InsightsEngine output is frozen:** its existing tests must pass unmodified after the StatsMath extraction — the refactor moves code verbatim, no behavior drift.
- No schema changes, no v2 wire changes, no new entitlements, no new permissions, no Info.plist changes. Correlations are recomputed, never persisted.
- Every threshold lives as a documented public `static let` on CorrelationEngine; tests assert the literal values so a silent threshold change breaks loudly.
- Statistics claims are verified against the fixtures, not trusted: every interval/p-value primitive gets at least one test against an externally-computed reference value (cite the reference — R/scipy output — in the test comment).
- Accessibility bar (plan 17): every new row/section carries identifiers + labels; Dynamic Type survives XXL; findings are `accessibilityElement(children: .combine)` cards like InsightsView.
- Rebase-aware: plan 26 (PR #25, connection granularity) and plan 28 (time type) may merge before execution — Task 2 and the design decisions above say exactly what changes in each case.
- Suites green before every commit; scoped commit + push per task; `git pull --rebase` before starting/pushing (standing instruction). Do NOT bump the build number.

---

### Task 1: Kit — StatsMath primitives (extraction + new inference machinery)

**Files:**
- Create: `Sources/DispatchKit/Insights/StatsMath.swift`
- Modify: `Sources/DispatchKit/Insights/InsightsEngine.swift` (delete private `mean`/`standardDeviation`, call StatsMath)
- Test: create `Tests/DispatchKitTests/StatsMathTests.swift`

**Interfaces (produced — Tasks 2/3 rely on these exact names):**

```swift
/// Internal statistics primitives shared by InsightsEngine and
/// CorrelationEngine. Pure, deterministic, dependency-free.
enum StatsMath {
    static func mean(_ values: [Double]) -> Double
    /// Population SD (divisor n) — moved VERBATIM from InsightsEngine.
    static func standardDeviation(_ values: [Double]) -> Double
    /// Wilson score interval for a proportion.
    static func wilsonInterval(successes: Int, trials: Int, confidence: Double) -> ClosedRange<Double>
    /// Newcombe MOVER difference-of-proportions interval (p1 − p2).
    static func newcombeDifferenceInterval(successes1: Int, trials1: Int,
                                           successes2: Int, trials2: Int,
                                           confidence: Double) -> ClosedRange<Double>
    /// Two-proportion z-test p-value (two-sided, pooled).
    static func twoProportionPValue(successes1: Int, trials1: Int,
                                    successes2: Int, trials2: Int) -> Double
    /// Welch's t: (deltaInterval, pValue) for mean(a) − mean(b), two-sided.
    static func welch(_ a: [Double], _ b: [Double], confidence: Double)
        -> (interval: ClosedRange<Double>, pValue: Double)
    static func pearsonR(_ pairs: [(Double, Double)]) -> Double
    /// Fisher-z interval + two-sided p-value for a Pearson r at sample size n.
    static func fisher(r: Double, count: Int, confidence: Double)
        -> (interval: ClosedRange<Double>, pValue: Double)
    /// Benjamini–Hochberg: indices of hypotheses rejected at rate q.
    /// Deterministic under ties (stable sort by (p, index)).
    static func benjaminiHochberg(pValues: [Double], q: Double) -> Set<Int>
    /// Standard normal CDF via erf (Darwin/Glibc).
    static func normalCDF(_ z: Double) -> Double
    /// Student-t CDF for Welch p-values/intervals: implement via the
    /// regularized incomplete beta (continued-fraction, Numerical-Recipes
    /// form) — pure Swift, no dependency. Accuracy pinned by reference tests.
    static func studentTCDF(_ t: Double, df: Double) -> Double
}
```

- [ ] **Step 1: Write the failing tests.** `StatsMathTests.swift`, every claim pinned to an EXTERNALLY computed reference (cite `R` / `scipy.stats` output in a comment beside each expectation, tolerance 1e-3 unless noted): (a) `mean`/`standardDeviation` — same values InsightsEngine produced (population SD: `[2,4,4,4,5,5,7,9]` → 2.0); (b) Wilson — `successes: 8, trials: 10, confidence: 0.95` → (0.490, 0.943); degenerate 0/10 and 10/10 stay inside [0,1] and are non-empty; (c) Newcombe — 8/10 vs 2/10 → interval ≈ (0.170, 0.808) (scipy reference; MOVER method); interval always contains the point estimate; (d) two-proportion p — 8/10 vs 2/10 → p ≈ 0.0073 (pooled z = 2.683); (e) Welch — `a = [1,2,3,4,5]`, `b = [2,4,6,8,10]` → t ≈ −1.512, df ≈ 5.35, p ≈ 0.189, CI ≈ (−8.01, 2.01) (scipy `ttest_ind(equal_var=False)`); (f) `pearsonR` — perfectly linear pairs → 1.0; anti-linear → −1.0; a fixed 20-point reference set → r matches scipy to 1e-6; (g) `fisher` — r = 0.5, n = 30 → CI ≈ (0.160, 0.741), p ≈ 0.0049; (h) `benjaminiHochberg` — the textbook example `[0.001, 0.008, 0.039, 0.041, 0.042, 0.06, 0.074, 0.205, 0.212, 0.216, 0.222, 0.251, 0.269, 0.275, 0.34]` at q = 0.05 rejects exactly the first four (BH steps up past 0.041 and 0.042 — verify against R `p.adjust`); empty input → empty set; all-1.0 → empty set; determinism under tied p-values; (i) `studentTCDF` — CDF(2.0, df: 10) ≈ 0.9633, CDF(0, any df) = 0.5.
- [ ] **Step 2: Run `swift test` — expect FAIL** (StatsMath doesn't exist).
- [ ] **Step 3: Implement** `StatsMath.swift` per the interface. `normalCDF` = `0.5 * erfc(-z / 2.0.squareRoot())`. `studentTCDF` via the regularized incomplete beta continued fraction — keep it private-helper'd and commented with the source form. Move `mean`/`standardDeviation` out of InsightsEngine verbatim and update its two call sites (`internal` visibility — same module).
- [ ] **Step 4: Run `swift test` — expect PASS**, INCLUDING the untouched `InsightsEngineTests` (the freeze constraint: extraction is behavior-neutral).
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): StatsMath — shared inference primitives (Wilson, Newcombe, Welch, Fisher, BH)"` → push.

### Task 2: Kit — CorrelationEngine: dimensions, targets, guards

**Files:**
- Create: `Sources/DispatchKit/Insights/CorrelationEngine.swift`
- Test: create `Tests/DispatchKitTests/CorrelationEngineTests.swift`

**Interfaces (produced — Task 3/4 rely on these exact names):**

```swift
/// Per-question correlation drill-in (plan 34, issue #19). Exhaustive over
/// context dimensions with EXPLICIT nulls: every dimension yields a finding,
/// a no-reliable-link row, or an insufficient-data row. THE HONESTY GUARDS
/// ARE THE FEATURE — see the threshold constants; nothing surfaces as a
/// finding below them, and nothing below them is silently hidden either.
public enum CorrelationEngine {
    public static let minimumSideCount = 10
    public static let minimumPairCount = 20
    public static let minimumEligibleAnswers = 20
    public static let minimumRateDelta = 0.15
    public static let minimumStandardizedDifference = 0.35
    public static let minimumPearsonR = 0.30
    public static let falseDiscoveryRate = 0.05   // Benjamini–Hochberg q
    public static let confidence = 0.95           // interval level (display + gate)
    public static let maximumTargets = 8          // per multi-answer question
    public static let maximumPeopleDimensions = 8
    public static let maximumPlaceDimensions = 8

    /// Standing correlation-≠-causation copy — rendered verbatim by every UI.
    public static let causationDisclaimer: String

    /// Question IDs with ≥ minimumEligibleAnswers answered filed reports,
    /// v1 target kinds only, deterministic order (answer count desc, prompt asc).
    public static func eligibleQuestionIDs(reports: [Report], questions: [Question]) -> [String]

    /// nil when the question is unknown/ineligible.
    public static func compute(questionID: String, reports: [Report],
                               questions: [Question],
                               people: [PersonEntity] = []) -> QuestionCorrelations?
}

public struct QuestionCorrelations: Equatable, Sendable {
    public var questionID: String
    public var prompt: String
    /// One group per target (yesNo/number → exactly one; choices/tokens →
    /// top maximumTargets by answer count). `isTruncated` drives the
    /// "showing your N most common answers" caption.
    public var targets: [TargetCorrelations]
    public var isTruncated: Bool
}

public struct TargetCorrelations: Equatable, Sendable {
    /// e.g. "Yes", "Red", "coffee" — or the prompt itself for number questions.
    public var label: String
    public var rows: [CorrelationRow]
}

public struct CorrelationRow: Equatable, Sendable {
    public enum Dimension: Equatable, Sendable {
        case person(name: String)
        case place(name: String)
        case connection(label: String)
        case timeOfDay(bucket: String)      // "Morning"/"Afternoon"/"Evening"/"Night"
        case sleepHours, steps, heartRateAvg, restingHeartRate
    }
    public var dimension: Dimension
    public var outcome: Outcome

    public enum Outcome: Equatable, Sendable {
        case finding(CorrelationFinding)
        /// Minimums met, tested, and nothing held up (below effect floor
        /// and/or not BH-significant). sampleCount = reports compared.
        case noReliableLink(sampleCount: Int)
        /// Guards not met — have/needed for the binding constraint.
        case insufficientData(have: Int, needed: Int)
    }
}

public struct CorrelationFinding: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case rateDifference, meanDifference, pearson
    }
    public enum Tier: String, Equatable, Sendable { case weak, moderate, strong }
    public var kind: Kind
    public var tier: Tier
    /// Signed raw effect: rate delta in [−1,1], mean difference in the
    /// metric's unit, or Pearson r.
    public var effect: Double
    /// Confidence interval on `effect` at `confidence` (95%).
    public var interval: ClosedRange<Double>
    public var pValue: Double
    /// e.g. ("72% of 25", "41% of 34") or ("7.2 h over 22", "6.1 h over 30").
    public var withSummary: String
    public var withoutSummary: String
    public var sampleCount: Int
}
```

- [ ] **Step 1: Write the failing tests** — synthetic fixtures with KNOWN ground truth (the InsightsEngineTests fixture style: private `day(_:)`, `makeQuestion`, `makeReport` helpers; reuse or mirror, don't import test code across files):
  - **Planted rate difference:** 60 reports, yesNo question answered on all; person "Angela" present on 25 (Yes on 18 of those = 72%), absent on 35 (Yes on 8 = 23%). Expect: person row is `.finding`, kind `.rateDifference`, effect ≈ +0.49, interval excludes 0, tier `.strong`, `withSummary` contains "72%" and "25".
  - **Planted mean difference:** yesNo target; sleep readings (type "sleepCore", seconds) planted so Yes-reports average 8 h, No-reports 6 h, within-side SD ~0.5 h → sleep row `.finding`, kind `.meanDifference`, effect ≈ +2.0 (hours), interval excludes 0.
  - **Planted Pearson:** number question vs steps, `steps = 1000 × answer + seeded noise` (fixed-seed LCG in the fixture, never `Double.random` unseeded) → steps row `.finding`, kind `.pearson`, r > 0.8, tier `.strong`.
  - **Noise yields explicit nulls, not findings:** seeded-random answers against all dimensions on 80 reports → every row with met minimums is `.noReliableLink`, NONE is `.finding` (probabilistic in principle; the seed is fixed, so assert the literal outcome).
  - **BH multiplicity:** one planted person effect among 7 noise people + noise places + time buckets → exactly the planted dimension surfaces as a finding; the rest are nulls. This is the test that fails if anyone later swaps BH for naive per-comparison gating.
  - **Below effect floor stays a null:** planted rate delta 0.08 with n = 200 per side (tiny but "significant") → `.noReliableLink` — the floor gate, independent of p.
  - **Insufficient data is explicit:** person present on only 4 reports → `.insufficientData(have: 4, needed: 10)`; sleep readings on 12 reports total for a Pearson pairing → `insufficientData(have: 12, needed: 20)`.
  - **Missing ≠ absence:** sleep dimension universe = only reports WITH sleep readings; a fixture where No-reports simply lack sleep data must not fabricate a difference. Person eligibility = reports where the owning people question was answered (question adopted mid-history fixture, mirroring `questionAdoptedMidHistoryOnlyCountsAnsweredReports`).
  - **Self-pairing exclusion:** a people question as target has NO person rows for its own tokens.
  - **Time zones:** two reports at the same UTC instant, `timeZoneIdentifier` "Asia/Tokyo" vs "America/Los_Angeles" → land in different time-of-day buckets.
  - **Connection categories:** reports with connection raws 1 and 0 → "Wi-Fi" and "Cellular" dimensions; raw 99 → excluded. If plan 26 has merged, also raw 5 → "LTE" (write the test against whichever taxonomy is on main at implementation).
  - **Eligibility + determinism:** `eligibleQuestionIDs` excludes location/note and under-20-answer questions, deterministic order; `compute` output is input-order invariant (shuffle reports, same result); drafts excluded; multi-choice question yields per-choice targets capped at 8 with `isTruncated` true.
  - **Threshold freeze:** literal assertions on every public constant (`#expect(CorrelationEngine.minimumSideCount == 10)` …) so silent tuning breaks loudly.
- [ ] **Step 2: Run `swift test` — expect FAIL.**
- [ ] **Step 3: Implement.** Structure mirrors InsightsEngine: stable report sort (date, then uniqueIdentifier) → build the target sets (per-question response index, answeredOptions/numericResponse/tokens per kind, PersonResolver for people questions) → build dimension sets (people/places with owner-based eligibility; connection; time-of-day via a per-report `Calendar` in `TimeZone(identifier: report.timeZoneIdentifier)`; health numerics keyed by report index) → per target × dimension compute the appropriate statistic via StatsMath → collect p-values per drill-in, run `benjaminiHochberg` → classify each row finding/null/insufficient. Tier mapping per the design decision. `withSummary`/`withoutSummary` composed with the locale-pinned formatters (copy the `en_US_POSIX` helpers pattern; hours one-decimal, steps grouped, rates as integer percents).
- [ ] **Step 4: Run `swift test` — expect PASS** (whole kit suite; InsightsEngineTests still untouched and green).
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): CorrelationEngine — per-question drill-in with honesty guards (BH, intervals, floors)"` → push.

### Task 3: Kit — copy layer: headlines, details, banned-language tests

**Files:**
- Modify: `Sources/DispatchKit/Insights/CorrelationEngine.swift` (or a sibling `CorrelationCopy.swift` if the file crowds past ~600 lines)
- Test: extend `Tests/DispatchKitTests/CorrelationEngineTests.swift`

**Interfaces (produced):**
- `CorrelationFinding.headline(targetLabel: String, prompt: String) -> String`
- `CorrelationFinding.detail: String` (composed from with/without summaries + interval + n)
- `CorrelationRow.Dimension.displayLabel: String` ("Angela", "Office", "Wi-Fi", "Morning", "Sleep", "Steps", "Average heart rate", "Resting heart rate")

- [ ] **Step 1: Write the failing tests.** (a) Template coverage — one expected-literal test per kind × direction: rateDifference positive → `"You answered Yes more often when Angela was around."` / detail `"Yes on 72% of 25 reports with Angela vs 41% of 34 without — a 31-point difference (95% CI 8 to 52)."`; meanDifference with a health noun → `"You slept longer on reports where you answered Yes."` detail `"Average 8.0 h over 22 reports vs 6.1 h over 30 — difference 1.9 h (95% CI 1.2 to 2.6)."`; pearson → `"Your answers to “Hours focused?” tend to rise and fall with your steps."` detail carrying `r = 0.84 (95% CI 0.71 to 0.92) over 41 reports"`. Context-only dimensions (place/connection/time) phrase as "at Office" / "on Wi-Fi" / "in the morning" — the InsightsEngine place-honesty precedent. (b) **Banned-language test** (the `languageStaysAssociationalNeverCausal` pattern): run the planted fixtures, collect every headline/detail plus `causationDisclaimer`, assert none contains (case-insensitive) `"2x"`, `"twice as likely"`, `"causes"`, `"caused by"`, `"because"`, `"leads to"`, `"makes you"`, `"proves"`, `"drives"` — EXCEPT the disclaimer's own "which drives which" phrasing; scope the check accordingly or reword the disclaimer to avoid the word (prefer rewording — keep the ban absolute). (c) Disclaimer constant is non-empty and mentions both "correlations" and "not causes".
- [ ] **Step 2: `swift test` — FAIL.**
- [ ] **Step 3: Implement** the templates (kind × direction × dimension-phrase table; direction from `effect.sign`; interval formatted in the effect's own unit — points for rates, the metric unit for means, bare r for Pearson).
- [ ] **Step 4: `swift test` — PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): correlation copy layer — interval-forward language, causation disclaimer"` → push.

### Task 4: App — CORRELATIONS section + per-question drill-in

**Files:**
- Create: `App/Sources/Insights/QuestionCorrelationView.swift`
- Modify: `App/Sources/Insights/InsightsView.swift`

**Interfaces (consumed):** Task 2/3's `CorrelationEngine`, `QuestionCorrelations`, `CorrelationRow`, `CorrelationFinding`, `causationDisclaimer`.

- [ ] **Step 1: InsightsView section.** Beneath the existing insight cards (and ABOVE the empty state handling — correlations can be eligible while the top-8 feed is empty, and vice versa): a `CORRELATIONS` header (caption style matching the card captions), one `NavigationLink` row per `CorrelationEngine.eligibleQuestionIDs` question (prompt + answered-count caption), identifier `correlation-question-row`. Hidden entirely when no question is eligible, with a one-line footnote under the explainer instead ("Per-question correlations unlock at 20 answers to a question."). Extend `insightsTaskID` — no new components needed (report count/newest/identity + question count + people fingerprint already cover the drill-list inputs); recompute `eligibleQuestionIDs` in the same `.task`.
- [ ] **Step 2: QuestionCorrelationView.** `@Query` reports/questions/people; memoized `.task(id:)` compute of `CorrelationEngine.compute(questionID:…)` (same fingerprint recipe). Layout per target group: target label header, then one card per row — dimension `displayLabel`, then by outcome: **finding** → headline (`.headline`), detail (`.subheadline`), tier + n caption (`"MODERATE · 59 REPORTS"`, the InsightsView caption styling); **noReliableLink** → muted row "No reliable link — tested across N reports"; **insufficientData** → muted row "Not enough data yet (have 4, needs 10 per side)". Findings sort first (|normalized effect| desc), then nulls, then insufficient (each alphabetical by label). Sticky footer text = `CorrelationEngine.causationDisclaimer`, identifier `correlation-disclaimer`, always visible in the scroll content (not conditional on findings). Identifiers: `question-correlations-view`, `correlation-finding-card`, `correlation-null-row`, `correlation-insufficient-row`. Plan 27 conventions: `readableColumn()` on the stack, adaptive grid at regular width for the cards. Theme: same dark card styling as InsightsView (`Color.white.opacity(0.12)` cards on `Color.themeBackground`).
- [ ] **Step 3: Verify** — `swift test` (kit untouched), `xcodebuild build-for-testing`. Sim smoke: seed demo data (`DemoData`), open Insights → a question row appears → drill-in renders findings/nulls with the disclaimer footer; a fresh install shows the unlock footnote and no section.
- [ ] **Step 4: Commit** — `git commit -m "feat: correlations section + per-question drill-in on Insights"` → push.

### Task 5: UI test + merge gate

**Files:**
- Modify: `AppUITests/InsightsUITests.swift`

- [ ] **Step 1: UI test.** Extend `InsightsUITests` (existing `--mock-sensors` empty-store test stays): fresh store → open Insights → `correlation-question-row` does NOT exist and the unlock footnote does (identifier it in Task 4). If the suite has a demo-data path (`ScreenshotTests` seeds demo — check whether `DemoData` seeding is reachable under a launch argument; if not, the empty-store assertions are the whole UI test and the drill-in stays covered by kit tests + the Task 4 sim smoke — record which in the completion note).
- [ ] **Step 2: Merge gate** — full `swift test`, `xcodebuild build-for-testing`, UI suite. Counts vs the pre-plan baseline; InsightsEngineTests unchanged and green.
- [ ] **Step 3: Commit** — `git commit -m "test: correlations UI coverage + merge-gate run"` → push. Whole-branch review follows (controller-driven). Completion note records: plan 26/28 merge state encountered and which conditional path was taken; the hrvSDNN and digest-integration follow-ups; the time-question integration point if plan 28 landed.

## Observable Acceptance Criteria

- Insights (from Settings → Insights, `insights-view`) shows a **CORRELATIONS**
  header beneath the insight cards with one tappable row per eligible question
  (`correlation-question-row`), each showing the prompt and an answer-count
  caption (e.g. `40 ANSWERS`).
- On a fresh install (no eligible question) the CORRELATIONS section is absent
  and a one-line footnote reads "Per-question correlations unlock at 20 answers
  to a question." (`correlations-unlock-footnote`).
- Tapping a question row opens the drill-in (`question-correlations-view`)
  titled with the prompt. Every context dimension renders exactly one row:
  - a finding card (`correlation-finding-card`) with the dimension label, a
    headline like "You answered Yes more often when Angela was around.", a
    detail carrying both sides + 95% CI + n, and a tier caption like
    `MODERATE · 59 REPORTS`;
  - or a muted "No reliable link — tested across N reports" row
    (`correlation-null-row`);
  - or a muted "Not enough data yet (have 4, needs 10)" row
    (`correlation-insufficient-row`).
- Multi-answer questions group rows under per-answer headers (e.g. `RED`),
  with "Showing your 8 most common answers." when truncated.
- The correlation-≠-causation disclaimer (`correlation-disclaimer`) is always
  present at the end of the drill-in scroll content, findings or not.
- No headline or detail anywhere claims causation ("causes", "because",
  "leads to", "makes you", "2x", "twice as likely", "proves", "drives") —
  pinned by kit test.
