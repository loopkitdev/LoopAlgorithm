//
//  Phase2PhysicalEgpTests.swift
//  LoopAlgorithm
//
//  Phase 2: the `.physicalDelivery` sensitivity decomposition splits a dose's
//  glucose effect into the PHYSICAL delivered insulin (volume × -activeISF,
//  always lowering) and the scheduled-basal EGP offset (schedOffset × egpISF,
//  raising). Unlike `.netBasalUnits` (sign-split), a sub-basal delivery keeps
//  active = volume, so boosting activeSensitivity amplifies the real insulin.
//
//  Invariant for BOTH decompositions: at activeISF == egpISF the result equals
//  the classic netBasalUnits × -ISF formula.
//

import XCTest
@testable import LoopAlgorithm

final class Phase2PhysicalEgpTests: XCTestCase {

    private let unit = LoopUnit.milligramsPerDeciliter
    private let dia = InsulinMath.defaultInsulinActivityDuration

    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
    private func date(_ s: String) -> Date { df.date(from: s)! }

    private func isf(_ v: Double, around t: Date) -> [AbsoluteScheduleValue<LoopQuantity>] {
        [AbsoluteScheduleValue(startDate: t.addingTimeInterval(-.hours(24)),
                               endDate: t.addingTimeInterval(.hours(24)),
                               value: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: v))]
    }

    // A temp basal delivering BELOW scheduled (sub-basal): net negative.
    private func subBasal(_ start: Date) -> BasalRelativeDose {
        // scheduled 1.2 U/hr, delivered 0.6 U/hr for 1h ⇒ volume 0.6, net -0.6
        BasalRelativeDose(type: .basal(scheduledRate: 1.2),
                          startDate: start, endDate: start.addingTimeInterval(.hours(1)),
                          volume: 0.6)
    }

    // MARK: - Identity: both decompositions == net when ISFs equal

    func testBothDecompositionsEqualNetWhenISFsEqual() {
        let start = date("2025-01-01T12:00:00")
        let dose = subBasal(start)
        let evalT = start.addingTimeInterval(.hours(3))
        let classic = dose.glucoseEffect(at: evalT, insulinSensitivity: 50, delta: .minutes(5))
        for d in [SensitivityDecomposition.netBasalUnits, .physicalDelivery] {
            let v = dose.glucoseEffect(at: evalT, activeSensitivity: 50, scheduleBaselineSensitivity: 50,
                                       delta: .minutes(5), decomposition: d)
            XCTAssertEqual(v, classic, accuracy: 1e-12,
                "Decomposition \(d) must equal classic net formula when ISFs are equal")
        }
    }

    func testDecomposedUnitsInvariant() {
        // active - egpRaise == netBasalUnits for both modes.
        let start = date("2025-01-01T12:00:00")
        let dose = subBasal(start)  // volume 0.6, net -0.6
        let (aN, eN) = dose.decomposedUnits(.netBasalUnits)
        XCTAssertEqual(aN - eN, dose.netBasalUnits, accuracy: 1e-12)
        XCTAssertEqual(aN, 0.0, accuracy: 1e-12)        // sub-basal ⇒ no active under net
        XCTAssertEqual(eN, 0.6, accuracy: 1e-12)
        let (aP, eP) = dose.decomposedUnits(.physicalDelivery)
        XCTAssertEqual(aP - eP, dose.netBasalUnits, accuracy: 1e-12)
        XCTAssertEqual(aP, 0.6, accuracy: 1e-12)        // physical = volume
        XCTAssertEqual(eP, 1.2, accuracy: 1e-12)        // scheduled offset = 1.2 U/hr × 1h
    }

    // MARK: - The core Phase-2 behavior

    func testActiveBoostAmplifiesSubBasalUnderPhysicalNotNet() {
        let start = date("2025-01-01T12:00:00")
        let dose = subBasal(start)
        let evalT = start.addingTimeInterval(dia + .hours(1))   // fully absorbed

        // baseline (no boost): both modes equal net (negative net ⇒ positive effect, raises BG)
        let baseNet = dose.glucoseEffect(at: evalT, activeSensitivity: 50, scheduleBaselineSensitivity: 50,
                                         delta: .minutes(5), decomposition: .netBasalUnits)
        let basePhys = dose.glucoseEffect(at: evalT, activeSensitivity: 50, scheduleBaselineSensitivity: 50,
                                          delta: .minutes(5), decomposition: .physicalDelivery)
        XCTAssertEqual(baseNet, basePhys, accuracy: 1e-12)
        XCTAssertGreaterThan(baseNet, 0, "Sub-basal net is negative ⇒ EGP-credit raises BG")

        // Boost activeSensitivity 2×, keep egp at scheduled.
        let boostNet = dose.glucoseEffect(at: evalT, activeSensitivity: 100, scheduleBaselineSensitivity: 50,
                                          delta: .minutes(5), decomposition: .netBasalUnits)
        let boostPhys = dose.glucoseEffect(at: evalT, activeSensitivity: 100, scheduleBaselineSensitivity: 50,
                                           delta: .minutes(5), decomposition: .physicalDelivery)

        // NET: active term is 0 for a sub-basal dose ⇒ boost does NOTHING.
        XCTAssertEqual(boostNet, baseNet, accuracy: 1e-12,
            "Under net decomposition, boosting activeSensitivity cannot touch a sub-basal dose")

        // PHYSICAL: active = volume (0.6) gets boosted ⇒ effect moves DOWN (more lowering).
        XCTAssertLessThan(boostPhys, basePhys,
            "Under physical decomposition, boosting activeSensitivity amplifies the real insulin")
        // Direction check: with enough boost the dose's net effect can flip from
        // raising (EGP-credit) to lowering.
        // effect = 0.6×-100×pd + 1.2×50×pd = (-60 + 60)×pd = 0 at exactly 2× here.
        XCTAssertEqual(boostPhys, 0, accuracy: 1e-9,
            "0.6×-100 + 1.2×50 = 0: physical insulin now exactly offsets its EGP credit")
    }

    func testStrongerBoostDrivesSubBasalNetLowering() {
        let start = date("2025-01-01T12:00:00")
        let dose = subBasal(start)
        let evalT = start.addingTimeInterval(dia + .hours(1))
        // 3× active boost: 0.6×-150 + 1.2×50 = -90 + 60 = -30 (lowers BG)
        let v = dose.glucoseEffect(at: evalT, activeSensitivity: 150, scheduleBaselineSensitivity: 50,
                                   delta: .minutes(5), decomposition: .physicalDelivery)
        XCTAssertLessThan(v, 0, "Strong active boost makes a sub-basal delivery a net BG-lowering effect")
    }

    // MARK: - Collection level + generatePrediction

    func testCollectionPhysicalEqualsNetWhenSchedulesEqual() {
        let start = date("2025-01-01T12:00:00")
        let doses = [subBasal(start),
                     BasalRelativeDose(type: .bolus, startDate: start.addingTimeInterval(.hours(2)),
                                       endDate: start.addingTimeInterval(.hours(2)), volume: 1.0)]
        let s = isf(50, around: start)
        let net = doses.glucoseEffects(insulinSensitivityHistory: s, scheduleBaselineSensitivityHistory: s,
                                       decomposition: .netBasalUnits)
        let phys = doses.glucoseEffects(insulinSensitivityHistory: s, scheduleBaselineSensitivityHistory: s,
                                        decomposition: .physicalDelivery)
        XCTAssertEqual(net.count, phys.count)
        for i in 0..<net.count {
            XCTAssertEqual(net[i].quantity.doubleValue(for: unit),
                           phys[i].quantity.doubleValue(for: unit), accuracy: 1e-9)
        }
    }

    func testMidAbsorptionPhysicalEqualsNetWhenSchedulesEqual() {
        let start = date("2025-01-01T12:00:00")
        let doses = [subBasal(start)]
        let s = isf(50, around: start)
        let net = doses.glucoseEffectsMidAbsorptionISF(insulinSensitivityHistory: s,
                    scheduleBaselineSensitivityHistory: s, decomposition: .netBasalUnits)
        let phys = doses.glucoseEffectsMidAbsorptionISF(insulinSensitivityHistory: s,
                    scheduleBaselineSensitivityHistory: s, decomposition: .physicalDelivery)
        XCTAssertEqual(net.count, phys.count)
        for i in 0..<net.count {
            XCTAssertEqual(net[i].quantity.doubleValue(for: unit),
                           phys[i].quantity.doubleValue(for: unit), accuracy: 1e-9)
        }
    }
}
