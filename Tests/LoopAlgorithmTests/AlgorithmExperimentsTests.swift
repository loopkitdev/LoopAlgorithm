//
//  AlgorithmExperimentsTests.swift
//  LoopAlgorithmTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import LoopAlgorithm

final class AlgorithmExperimentsTests: XCTestCase {

    private let unit = LoopUnit.milligramsPerDeciliter

    private func loadScenario(_ name: String) -> AlgorithmInputFixture {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let url = Bundle.module.url(forResource: name + "_scenario", withExtension: "json", subdirectory: "Fixtures")!
        return try! decoder.decode(AlgorithmInputFixture.self, from: try! Data(contentsOf: url))
    }

    private func glucoseSeries(_ values: [Double], endingAt end: Date, spacing: TimeInterval = .minutes(5)) -> [FixtureGlucoseSample] {
        values.enumerated().map { i, v in
            FixtureGlucoseSample(startDate: end.addingTimeInterval(-Double(values.count - 1 - i) * spacing), quantity: .glucose(v))
        }
    }

    private func assertSameOutput(_ a: AlgorithmOutput<FixtureCarbEntry>, _ b: AlgorithmOutput<FixtureCarbEntry>,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.recommendation, b.recommendation, file: file, line: line)
        XCTAssertEqual(a.predictedGlucose.map { $0.quantity.doubleValue(for: unit) },
                       b.predictedGlucose.map { $0.quantity.doubleValue(for: unit) }, file: file, line: line)
    }

    // MARK: - Default is standard LoopAlgorithm

    func testExistingFixturesDecodeWithoutExperiments() {
        XCTAssertNil(loadScenario("suspend").experiment)
        XCTAssertNil(loadScenario("carbs_with_isf_change").experiment)
    }

    func testGatedExperimentsAreInertWhenTheirGateIsClosed() {
        // Mock: glucose rising 100 -> 160, no low, below 180. With carbs on board the band is gated off,
        // there is no low for the post-low cut, and the licence needs >= 180: the stack must change nothing.
        let now = ISO8601DateFormatter().date(from: "2024-01-03T12:00:00+0000")!
        var input = AlgorithmInputFixture.mock(for: now)
        input.recommendationType = .automaticBolus
        input.carbEntries = [FixtureCarbEntry(absorptionTime: .hours(3), startDate: now.addingTimeInterval(.minutes(-30)), quantity: .carbs(30))]
        let standard = LoopAlgorithm.run(input: input)
        input.experiment = .stack
        input.volatilityBaseline = 5
        assertSameOutput(standard, LoopAlgorithm.run(input: input))
    }

    func testStackWithoutABaselineRunsOnlyThePostLowCut() {
        // No baseline and under a day of glucose: band and licence are off, so with no low nothing changes.
        let now = ISO8601DateFormatter().date(from: "2024-01-03T12:00:00+0000")!
        var input = AlgorithmInputFixture.mock(for: now)
        let standard = LoopAlgorithm.run(input: input)
        input.experiment = .stack
        assertSameOutput(standard, LoopAlgorithm.run(input: input))
        XCTAssertNil(ExperimentParameters(experiment: .stack, volatilityBaseline: nil).volatilityBand)
        XCTAssertNotNil(ExperimentParameters(experiment: .stack, volatilityBaseline: nil).postLowRiseCut)
    }

    func testAsymmetricIntegralRCTurnsIntegralRCOn() {
        var input = loadScenario("carbs_with_isf_change")
        input.experiment = .asymmetricIntegralRC
        input.useIntegralRetrospectiveCorrection = false
        let forced = LoopAlgorithm.run(input: input)
        input.useIntegralRetrospectiveCorrection = true
        assertSameOutput(forced, LoopAlgorithm.run(input: input))
        let p = ExperimentParameters(experiment: .asymmetricIntegralRC, volatilityBaseline: nil)
        XCTAssertEqual(p.retrospectiveCorrectionDropScale, 1.5)
        XCTAssertEqual(p.retrospectiveCorrectionRiseScale, 0.5)
        XCTAssertEqual(p.integralRetrospectiveCorrectionMaxVelocity, 4.0)
        XCTAssertNil(p.postLowRiseCut)
    }

    func testStackParameters() {
        let p = ExperimentParameters(experiment: .stack, volatilityBaseline: 5)
        XCTAssertEqual(p.volatilityBand?.gain, 1.0)                                   // min(1, 6.7 / 5)
        XCTAssertEqual(ExperimentParameters(experiment: .stack, volatilityBaseline: 10).volatilityBand!.gain, 0.67, accuracy: 1e-12)
        XCTAssertEqual(p.calmHighLicence?.maxVolatility, 5)
        XCTAssertEqual(p.postLowRiseCut, ExperimentParameters.PostLowRiseCut())
        XCTAssertEqual(ExperimentParameters(experiment: nil, volatilityBaseline: 5), ExperimentParameters.none)
    }

    // MARK: - Retrospective correction gains

    func testStandardRCRiseAndDropScales() {
        let now = Date()
        let latest = SimpleGlucoseValue(startDate: now, quantity: .glucose(150))
        func total(_ discrepancy: Double, drop: Double, rise: Double) -> Double {
            let rc = StandardRetrospectiveCorrection(effectDuration: .minutes(60), dropScale: drop, riseScale: rise)
            let change = GlucoseChange(startDate: now.addingTimeInterval(.minutes(-30)), endDate: now, quantity: .glucose(discrepancy))
            _ = rc.computeEffect(startingAt: latest, retrospectiveGlucoseDiscrepanciesSummed: [change],
                                 recencyInterval: .minutes(15), retrospectiveCorrectionGroupingInterval: .minutes(30))
            return rc.totalGlucoseCorrectionEffect!.doubleValue(for: unit)
        }
        XCTAssertEqual(total(10, drop: 1.5, rise: 0.5), 5, accuracy: 1e-9)
        XCTAssertEqual(total(-10, drop: 1.5, rise: 0.5), -15, accuracy: 1e-9)
        XCTAssertEqual(total(10, drop: 1, rise: 1), 10, accuracy: 1e-9)
    }

    func testIntegralRCVelocityCap() {
        let now = Date()
        let latest = SimpleGlucoseValue(startDate: now, quantity: .glucose(250))
        // A 30-min discrepancy of +200 mg/dL is a correction rate far above 4 mg/dL/min.
        let change = GlucoseChange(startDate: now.addingTimeInterval(.minutes(-30)), endDate: now, quantity: .glucose(200))
        let capped = IntegralRetrospectiveCorrection(effectDuration: .minutes(60), maxVelocity: 4.0)
        let effect = capped.computeEffect(startingAt: latest, retrospectiveGlucoseDiscrepanciesSummed: [change],
                                          recencyInterval: .minutes(15), retrospectiveCorrectionGroupingInterval: .minutes(30))
        let uncapped = IntegralRetrospectiveCorrection(effectDuration: .minutes(60))
        let effectU = uncapped.computeEffect(startingAt: latest, retrospectiveGlucoseDiscrepanciesSummed: [change],
                                             recencyInterval: .minutes(15), retrospectiveCorrectionGroupingInterval: .minutes(30))
        let rise: ([GlucoseEffect]) -> Double = { $0.last!.quantity.doubleValue(for: self.unit) - $0.first!.quantity.doubleValue(for: self.unit) }
        XCTAssertLessThan(rise(effect), rise(effectU))
        // First 5-min step can rise by at most 4 mg/dL/min * 5 min.
        XCTAssertLessThanOrEqual(effect[1].quantity.doubleValue(for: unit) - effect[0].quantity.doubleValue(for: unit), 20.0 + 1e-6)
    }

    // MARK: - Post-low rise-cut gate

    func testPostLowRiseCutGate() {
        let now = Date()
        let cut = ExperimentParameters.PostLowRiseCut()
        XCTAssertTrue(cut.isActive(glucoseHistory: glucoseSeries([90, 65, 80, 120], endingAt: now)))
        XCTAssertFalse(cut.isActive(glucoseHistory: glucoseSeries([90, 65, 120, 190], endingAt: now)), "released above 180")
        XCTAssertFalse(cut.isActive(glucoseHistory: glucoseSeries([90, 100, 110, 120], endingAt: now)), "no low")
        let old = [FixtureGlucoseSample(startDate: now.addingTimeInterval(.hours(-13)), quantity: .glucose(60))]
            + glucoseSeries([100, 110, 120], endingAt: now)
        XCTAssertFalse(cut.isActive(glucoseHistory: old), "low outside the 12 h window")
    }

    func testPostLowRiseCutLowersTheForecastAfterALow() {
        // Rebound after a low, with insulin on board: the unexplained rise is cut, so the forecast is lower.
        let now = ISO8601DateFormatter().date(from: "2024-01-03T12:00:00+0000")!
        var input = AlgorithmInputFixture.mock(for: now)
        input.glucoseHistory = glucoseSeries([62, 66, 75, 90, 110, 130], endingAt: now.addingTimeInterval(.minutes(-1)))
        let standard = LoopAlgorithm.run(input: input)
        input.experiment = .stack
        let cut = LoopAlgorithm.run(input: input)
        XCTAssertLessThan(cut.predictedGlucose.last!.quantity.doubleValue(for: unit),
                          standard.predictedGlucose.last!.quantity.doubleValue(for: unit))
    }

    // MARK: - Volatility

    func testSigma5() {
        let now = Date()
        XCTAssertEqual(GlucoseVolatility.sigma5(glucoseSeries([120, 120, 120, 120], endingAt: now)), (2 * 1.4 * 1.4).squareRoot(), accuracy: 1e-9)
        // Constant 10 mg/dL steps: the EWMA of 100 is 100.
        XCTAssertEqual(GlucoseVolatility.sigma5(glucoseSeries([100, 110, 120, 130, 140], endingAt: now)), 10, accuracy: 1e-9)
        // A gap > 7 min restarts the estimate: only the steps after the gap count.
        let gapped = glucoseSeries([100, 140, 180], endingAt: now.addingTimeInterval(.minutes(-30)))
            + glucoseSeries([100, 102], endingAt: now)
        XCTAssertEqual(GlucoseVolatility.sigma5(gapped), 2.0, accuracy: 1e-9)   // one 2 mg/dL step; 4 > floor 3.92
    }

    func testSigma5OnOneMinuteCGM() {
        // The same 10 mg/dL per 5 min trend sampled every minute must read like 5-minute data, not the floor.
        let now = Date()
        let oneMinute = (0...40).map { FixtureGlucoseSample(startDate: now.addingTimeInterval(.minutes(Double($0 - 40))), quantity: .glucose(100 + 2 * Double($0))) }
        XCTAssertEqual(GlucoseVolatility.sigma5(oneMinute), 10, accuracy: 1e-9)
    }

    func testBaselineIsTheMedianOfSigma5() {
        let now = Date()
        XCTAssertNil(GlucoseVolatility.baseline(glucoseSeries(Array(repeating: 120, count: 100), endingAt: now)), "under a day")
        // A calm stretch then a longer +/-10 stretch: the median is volatile, above the floor and at most 10.
        let flat = Array(repeating: 120.0, count: 100)
        let zig = (0..<200).map { $0 % 2 == 0 ? 120.0 : 130.0 }
        let b = GlucoseVolatility.baseline(glucoseSeries(flat + zig, endingAt: now))!
        XCTAssertGreaterThan(b, (2 * 1.4 * 1.4).squareRoot())
        XCTAssertLessThanOrEqual(b, 10)
    }

    func testVolatilityBandShape() {
        let now = Date()
        let glucose = (0...48).map { PredictedGlucoseValue(startDate: now.addingTimeInterval(.minutes(5 * Double($0))), quantity: .glucose(120)) }
        let band = ExperimentParameters.VolatilityBand(gain: 1.0)
        let banded = LoopAlgorithm.volatilityBanded(glucose, band: band, volatility: 4.0)
        let offset: (Int) -> Double = { banded[$0].quantity.doubleValue(for: self.unit) - 120 }
        XCTAssertEqual(offset(0), 0, accuracy: 1e-9)
        XCTAssertEqual(offset(12), -4.0 * pow(12.0, 0.71), accuracy: 1e-9)          // 60 min: full depth
        XCTAssertEqual(offset(18), -4.0 * pow(12.0, 0.71) / 2, accuracy: 1e-9)      // 90 min: half way down the taper
        XCTAssertEqual(offset(24), 0, accuracy: 1e-9)                               // 120 min: gone
        XCTAssertEqual(offset(48), 0, accuracy: 1e-9)                               // eventual untouched
    }

    // MARK: - Calm-high licence

    func testCalmHighLicenceDoublesTheApplicationFactorOnACalmHigh() {
        let now = ISO8601DateFormatter().date(from: "2024-01-03T12:00:00+0000")!
        var input = AlgorithmInputFixture.mock(for: now)
        input.recommendationType = .automaticBolus
        input.glucoseHistory = glucoseSeries([220, 220, 221, 220], endingAt: now.addingTimeInterval(.minutes(-1)))
        let standard = LoopAlgorithm.run(input: input).recommendation!.automatic!.bolusUnits!
        input.experiment = .stack
        input.volatilityBaseline = 5
        let licensed = LoopAlgorithm.run(input: input).recommendation!.automatic!.bolusUnits!
        XCTAssertGreaterThan(standard, 0)
        // AF 0.4 -> 0.8; the band (on, no carbs) lowers only the near-term forecast, so the bolus roughly doubles.
        XCTAssertGreaterThan(licensed, 1.5 * standard)
        XCTAssertLessThanOrEqual(licensed, 2 * standard + 0.051)
        // Volatile relative to the person's baseline: no licence. (The band is still on, and only lowers the dose.)
        input.volatilityBaseline = 0.5
        XCTAssertLessThanOrEqual(LoopAlgorithm.run(input: input).recommendation!.automatic!.bolusUnits!, standard + 1e-9)
    }

    // MARK: - Codable

    func testFixtureRoundTripCarriesTheExperiment() throws {
        var input = loadScenario("suspend")
        input.experiment = .stack
        input.volatilityBaseline = 4.2
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(AlgorithmInputFixture.self, from: encoder.encode(input))
        XCTAssertEqual(back.experiment, .stack)
        XCTAssertEqual(back.volatilityBaseline, 4.2)
        XCTAssertEqual(AlgorithmExperiment.allCases, [.asymmetricIntegralRC, .stack])
    }
}
