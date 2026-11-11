import XCTest
@testable import LoopAdaptive

/// Faulty and extreme inputs. The CGM is scripted (it does not respond to insulin) and the algorithm's own doses are
/// fed back as dose records, so each test measures the automatic insulin given, against a bound.
final class StressTests: XCTestCase {
    let profile = AdaptiveProfile(totalDailyDose: 40, basalRate: 0.8, setPoint: 130)
    let limits = AdaptiveLimits(maximumBolus: 10, bolusIncrement: 0.05, suspendThreshold: 70, maximumBasalRate: 4)
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    struct Run {
        var auto = 0.0; var firstHour = 0.0; var maxBolus = 0.0; var anyNaN = false; var scaleFinite = true
        var boluses: [(Double, Double)] = []                            // (minute, U)
        func given(from a: Double, to b: Double) -> Double { boluses.filter { $0.0 >= a && $0.0 < b }.reduce(0) { $0 + $1.1 } }
    }

    /// minutes since start -> readings in that cycle; doses reach the phone unless `recorded` says no.
    func run(hours: Double = 4, carbs: [AdaptiveCarbEntry] = [], recorded: @escaping (Double) -> Bool = { _ in true },
             historyDate: ((Date) -> Date?)? = nil, p: AdaptiveParameters = .candidate,
             cgm: @escaping (Double) -> [Double]) -> Run {
        var state = AdaptiveState(), glucose: [AdaptiveGlucoseSample] = [], doses: [AdaptiveDose] = [], r = Run()
        var m = -24.0 * 60
        while m < hours * 60 {
            let now = t0.addingTimeInterval(m * 60)
            for v in (m < 0 ? [120] : cgm(m)) { glucose.append(.init(date: now.addingTimeInterval(-5), value: v)) }
            glucose.removeAll { $0.date < now.addingTimeInterval(-3 * 3600) }
            doses.removeAll { $0.start < now.addingTimeInterval(-7 * 3600) }
            let input = AdaptiveInput(now: now, glucose: glucose, doses: doses, carbs: m < 0 ? [] : carbs, limits: limits,
                                      doseHistoryDate: m < 0 ? nil : historyDate?(now))
            let out = LoopAdaptive.recommend(input, profile: profile, state: &state, parameters: p)
            var new = [AdaptiveDose(start: now, end: now.addingTimeInterval(300), units: out.tempBasalRate / 12, kind: .basal, automatic: true)]
            if out.automaticBolus > 0 { new.append(.init(start: now, end: now, units: out.automaticBolus, kind: .bolus, automatic: true)) }
            if m < 0 || recorded(m) { doses += new }
            if m >= 0 {
                r.auto += out.automaticBolus; r.maxBolus = max(r.maxBolus, out.automaticBolus)
                if m < 60 { r.firstHour += out.automaticBolus }
                r.boluses.append((m, out.automaticBolus))
                if !out.automaticBolus.isFinite || !out.tempBasalRate.isFinite || !out.manualBolus.isFinite { r.anyNaN = true }
                if !state.logScale.isFinite { r.scaleFinite = false }
            }
            m += 5
        }
        return r
    }
    var unguarded: AdaptiveParameters { var p = AdaptiveParameters(); p.guardrails = false; return p }

    func testNoGlucoseNeverNaN() {
        for p in [AdaptiveParameters.candidate, unguarded] {
            let r = run(hours: 4, p: p) { m in m <= 10 ? [150] : [] }      // sensor lost after 10 min, for 4 h
            XCTAssertFalse(r.anyNaN); XCTAssertTrue(r.scaleFinite)
        }
    }
    func testStaleGlucoseStopsAutomaticBoluses() {
        let r = run(hours: 3) { m in m <= 10 ? [250] : [] }             // newest reading at 10 min (- 5 s)
        XCTAssertGreaterThan(r.given(from: 0, to: 25), 0)               // fresh readings are still acted on
        XCTAssertEqual(r.given(from: 25, to: 180), 0)                   // none once the reading is > 15 min old
        let off = run(hours: 3, p: unguarded) { m in m <= 10 ? [250] : [] }
        XCTAssertGreaterThan(off.given(from: 25, to: 180), 1)           // (without guardrails it keeps dosing)
    }
    func testLostDoseRecords() {
        let ok = run(hours: 4) { _ in [200] }
        let lost = run(hours: 4, recorded: { _ in false }) { _ in [200] }
        XCTAssertLessThanOrEqual(lost.auto, ok.auto + 0.05)             // its own issued boluses are remembered
        var noLedger = AdaptiveParameters(); noLedger.rememberIssuedBoluses = false
        let blind = run(hours: 4, recorded: { _ in false }, p: noLedger) { _ in [200] }
        XCTAssertGreaterThan(blind.auto, 3 * ok.auto)                   // (without the ledger it repeats the correction)
        let h = run(hours: 4, recorded: { _ in false }, historyDate: { $0.addingTimeInterval(-3600) }, p: noLedger) { _ in [200] }
        XCTAssertEqual(h.auto, 0)                                       // a stale pump read: no automatic bolus at all
    }
    func testActiveInsulinLimit() {
        var small = AdaptiveParameters(); small.activeInsulinMultiplier = 0.1   // 1 U of net IOB with max bolus 10 U
        let r = run(hours: 1, p: small) { _ in [300] }
        XCTAssertLessThanOrEqual(r.auto, 1.0 + 0.05 + 0.8)              // 1 U above basal, plus the hour's withheld basal
    }
    func testCarbTypoCapped() {
        let typo = run(carbs: [.init(date: t0, grams: 500)]) { _ in [120] }
        let cap = run(carbs: [.init(date: t0, grams: 250)]) { _ in [120] }
        XCTAssertEqual(typo.auto, cap.auto, accuracy: 1e-9)             // 500 g reads as 250 g
        XCTAssertLessThanOrEqual(typo.firstHour, 20.05)                 // and IOB stays under 2 × max bolus
    }
    func testFutureCarbsNotDosedAutomatically() {
        let fut = run(hours: 1, carbs: [.init(date: t0.addingTimeInterval(3 * 3600), grams: 50)]) { _ in [120] }
        let none = run(hours: 1) { _ in [120] }
        XCTAssertEqual(fut.auto, none.auto, accuracy: 1e-9)
    }
    func testSensorArtifacts() {
        let control = run { _ in [120] }.auto
        let spike = run { m in m == 30 ? [220] : [120] }.auto
        let compression = run { m in m >= 20 && m < 50 ? [55] : [120] }.auto
        let zero = run { m in m == 30 ? [0] : [120] }.auto
        XCTAssertLessThanOrEqual(spike - control, 0.1)
        XCTAssertLessThanOrEqual(compression - control, 0.3)
        XCTAssertLessThanOrEqual(zero - control, 0.1)
        // a level step is corrected as a level, without momentum on top: in the half hour after it, at most the
        // correction for the new level (60 mg/dL / ISF)
        let isf = 688 / pow(40, 0.74)
        let step = run { m in m < 30 ? [120] : [180] }
        XCTAssertLessThanOrEqual(step.given(from: 30, to: 60), 60 / isf + 0.1)
        let off = run(p: unguarded) { m in m < 30 ? [120] : [180] }
        XCTAssertGreaterThan(off.given(from: 30, to: 60), step.given(from: 30, to: 60))
    }
    func testRealFastRiseStillCorrected() {
        let r = run { m in [min(320, 120 + 4 * m)] }                    // +4 mg/dL/min, under the jump limit
        XCTAssertGreaterThan(r.auto, 8)
    }
}
