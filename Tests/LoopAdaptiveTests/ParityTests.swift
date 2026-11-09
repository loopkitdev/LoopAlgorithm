import XCTest
@testable import LoopAdaptive

/// Cycle-by-cycle parity with the Python reference (LoopEval `analysis/reduction/adaptive.py`, family tdd_pd).
/// Fixtures come from LoopEval `analysis/reduction/swift_fixtures.py`: closed-loop synthetic streams recorded as
/// events plus the reference's answer each cycle. Requests are rebuilt here exactly as that script built them.
final class ParityTests: XCTestCase {

    struct Fixture: Decodable {
        struct Over: Decodable { var start: Double; var end: Double; var target_lo: Double; var target_hi: Double; var factor: Double }
        struct Limits: Decodable { var max_bolus: Double?; var bolus_inc: Double?; var suspend: Double? }
        struct DoseRec: Decodable { var dose: [Value]; var cycle: Int }
        struct CarbRec: Decodable { var entry: [Value]; var cycle: Int }
        struct Out: Decodable { var bolus: Double; var temp_rate: Double; var manual_rec: Double?; var need: Double; var scale: Double; var rc: Double; var hab: Double; var gsl_hold: Bool }
        enum Value: Decodable {
            case s(String), d(Double), b(Bool)
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let v = try? c.decode(Bool.self) { self = .b(v) } else if let v = try? c.decode(Double.self) { self = .d(v) } else { self = .s(try c.decode(String.self)) }
            }
            var string: String { if case .s(let v) = self { return v }; fatalError() }
            var double: Double { if case .d(let v) = self { return v }; fatalError() }
            var bool: Bool { if case .b(let v) = self { return v }; fatalError() }
        }
        var name: String
        var params: [String: Double]
        var start: Double
        var cycles: Int
        var limits: Limits
        var user_target: [Double]?
        var overrides: [Over]
        var glucose: [[Value]]
        var doses: [DoseRec]
        var carbs: [CarbRec]
        var expected: [Out]
    }

    nonisolated(unsafe) static let iso = ISO8601DateFormatter()

    func parameters(_ q: [String: Double]) -> AdaptiveParameters {
        var p = AdaptiveParameters()
        p.carbRatioK = q["cr_k"] ?? 0
        p.retrospectiveGain = q["rc_k"] ?? 0
        p.adaptMinimum = q["ad_min"] ?? p.adaptMinimum
        p.adaptMaximum = q["ad_max"] ?? p.adaptMaximum
        p.adaptBrakeHours = q["ad_brake_h"] ?? 0
        p.glucoseSafetyLimit = q["gsl"] ?? 0
        p.glucoseSafetyLimitFromSettings = (q["gsl_settings"] ?? 1) != 0
        p.habitGain = q["hab_k"] ?? 0
        p.habitSkillReference = q["hab_ref"] ?? p.habitSkillReference
        return p
    }

    func runFixture(_ name: String) throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let p = parameters(fx.params)
        let useTarget = (fx.params["use_target"] ?? 0) != 0, useOverride = (fx.params["use_override"] ?? 0) != 0
        let profile = AdaptiveProfile(totalDailyDose: fx.params["tdd"]!, basalRate: fx.params["basal_uh"]!, setPoint: fx.params["ad_sp"]!)
        let date = { (s: String) -> Date in Self.iso.date(from: s)! }
        let glucose = fx.glucose.map { AdaptiveGlucoseSample(date: date($0[0].string), value: $0[1].double) }
        let doses = fx.doses.map { (AdaptiveDose(start: date($0.dose[0].string), end: date($0.dose[1].string), units: $0.dose[2].double,
                                                 kind: $0.dose[3].string == "bolus" ? .bolus : .basal, automatic: $0.dose[4].bool), $0.cycle) }
        let carbs = fx.carbs.map { (AdaptiveCarbEntry(date: date($0.entry[0].string), grams: $0.entry[1].double, absorptionTime: $0.entry[2].double), $0.cycle) }
        let limits = AdaptiveLimits(maximumBolus: fx.limits.max_bolus, bolusIncrement: fx.limits.bolus_inc, suspendThreshold: fx.limits.suspend)
        var state = AdaptiveState()
        var spent = 0.0
        var worst = (bolus: 0.0, temp: 0.0, manual: 0.0, need: 0.0, scale: 0.0, hab: 0.0)
        for i in 0..<fx.cycles {
            let t = fx.start + Double(i) * 300
            let g = Array(glucose[max(0, i - 39)...i])
            let d = doses.filter { $0.1 < i && $0.0.start.timeIntervalSince1970 > t - 7 * 3600 }.map(\.0)
            let c = carbs.filter { $0.1 <= i }.map(\.0)
            var ov: AdaptiveOverride? = nil
            if useOverride, let o = fx.overrides.first(where: { $0.start <= t && t < $0.end }) {
                ov = AdaptiveOverride(targetRange: o.target_lo...o.target_hi, insulinNeedsFactor: o.factor)
            }
            let ut = useTarget ? fx.user_target.map { $0[0]...$0[1] } : nil
            let input = AdaptiveInput(now: Date(timeIntervalSince1970: t + 5), glucose: g, doses: d, carbs: c, limits: limits,
                                      userTarget: ut, override: ov)
            let clock = Date()
            let r = LoopAdaptive.recommend(input, profile: profile, state: &state, parameters: p)
            spent += Date().timeIntervalSince(clock)
            let e = fx.expected[i]
            worst.bolus = max(worst.bolus, abs(r.automaticBolus - e.bolus))
            worst.temp = max(worst.temp, abs(r.tempBasalRate - e.temp_rate))
            worst.manual = max(worst.manual, abs(r.manualBolus - (e.manual_rec ?? 0)))
            worst.need = max(worst.need, abs(r.diagnostics.need - e.need))
            worst.scale = max(worst.scale, abs(r.diagnostics.scale - e.scale))
            worst.hab = max(worst.hab, abs(r.diagnostics.habitOffset - e.hab))
            XCTAssertEqual(r.diagnostics.glucoseSafetyHold, e.gsl_hold, "\(name) cycle \(i): safety hold")
            if abs(r.automaticBolus - e.bolus) > 1e-9 || abs(r.tempBasalRate - e.temp_rate) > 1e-9 || abs(r.manualBolus - (e.manual_rec ?? 0)) > 1e-9 {
                XCTFail("\(name) cycle \(i): swift bolus \(r.automaticBolus) temp \(r.tempBasalRate) manual \(r.manualBolus) need \(r.diagnostics.need) | python \(e.bolus) \(e.temp_rate) \(e.manual_rec ?? 0) \(e.need)")
                return
            }
        }
        print("\(name): \(fx.cycles) cycles, \(String(format: "%.3f", spent / Double(fx.cycles) * 1e3)) ms per cycle; worst |Δ| bolus \(worst.bolus) temp \(worst.temp) manual \(worst.manual) need \(worst.need) scale \(worst.scale) habit \(worst.hab)")
        XCTAssertLessThan(worst.need, 1e-9); XCTAssertLessThan(worst.scale, 1e-12); XCTAssertLessThan(worst.hab, 1e-9)
    }

    func testCandidate() throws { try runFixture("candidate") }
    func testTargetAndOverride() throws { try runFixture("target_override") }
    func testGlucoseSafetyLimit() throws { try runFixture("gsl") }
    func testHabit() throws { try runFixture("habit") }
    func testHabitSafetyLimitOverride() throws { try runFixture("habit_gsl_override") }

    func testProfileEstimate() {
        let p = AdaptiveProfile.estimate(dailyTotals: [40, 44], hourlyAutomaticDelivery: [0.5, 1.0, 0.8, 2.0], meanGlucose: 150)!
        XCTAssertEqual(p.totalDailyDose, 37.8, accuracy: 1e-12)
        XCTAssertEqual(p.basalRate, 0.81, accuracy: 1e-12)
        XCTAssertEqual(p.setPoint, 140)
    }

    func testNoInsulinWhenLow() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let g = (0..<12).map { AdaptiveGlucoseSample(date: now.addingTimeInterval(Double($0 - 11) * 300 - 5), value: 90 - Double($0) * 2) }
        var s = AdaptiveState()
        let r = LoopAdaptive.recommend(AdaptiveInput(now: now, glucose: g, doses: []), profile: .init(totalDailyDose: 40, basalRate: 0.8, setPoint: 130), state: &s)
        XCTAssertEqual(r.automaticBolus, 0); XCTAssertEqual(r.tempBasalRate, 0)
    }
}
