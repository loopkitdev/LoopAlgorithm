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
        XCTAssertTrue(loadScenario("suspend").experiments.isNone)
        XCTAssertTrue(loadScenario("carbs_with_isf_change").experiments.isNone)
    }

    func testExplicitNoneMatchesStandard() {
        for name in ["suspend", "carbs_with_isf_change"] {
            let standard = loadScenario(name)
            var explicit = standard
            explicit.algorithmExperiments = AlgorithmExperiments()
            assertSameOutput(LoopAlgorithm.run(input: standard), LoopAlgorithm.run(input: explicit))
        }
    }

    func testUnityScalesMatchStandard() {
        var input = loadScenario("carbs_with_isf_change")
        let standard = LoopAlgorithm.run(input: input)
        input.algorithmExperiments = AlgorithmExperiments(retrospectiveCorrectionDropScale: 1.0, retrospectiveCorrectionRiseScale: 1.0)
        assertSameOutput(standard, LoopAlgorithm.run(input: input))
    }

    func testGatedExperimentsAreInertWhenTheirGateIsClosed() {
        // Mock: glucose rising 100 -> 160, no low, below 180, no carbs. The post-low cut has no low to
        // key on and the calm-high licence needs >= 180, so both must leave the output unchanged.
        let now = ISO8601DateFormatter().date(from: "2024-01-03T12:00:00+0000")!
        var input = AlgorithmInputFixture.mock(for: now)
        input.recommendationType = .automaticBolus
        let standard = LoopAlgorithm.run(input: input)
        input.algorithmExperiments = AlgorithmExperiments(
            postLowRiseCut: .init(),
            calmHighLicence: .init(maxVolatility: 100))
        assertSameOutput(standard, LoopAlgorithm.run(input: input))
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
        let cut = AlgorithmExperiments.PostLowRiseCut()
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
        input.algorithmExperiments = AlgorithmExperiments(postLowRiseCut: .init())
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

    func testVolatilityBandShape() {
        let now = Date()
        let glucose = (0...48).map { PredictedGlucoseValue(startDate: now.addingTimeInterval(.minutes(5 * Double($0))), quantity: .glucose(120)) }
        let band = AlgorithmExperiments.VolatilityBand(gain: 1.0)
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
        input.algorithmExperiments = AlgorithmExperiments(calmHighLicence: .init(maxVolatility: 5))
        let licensed = LoopAlgorithm.run(input: input).recommendation!.automatic!.bolusUnits!
        XCTAssertGreaterThan(standard, 0)
        XCTAssertEqual(licensed, min(2 * standard, standard / 0.4), accuracy: 0.051)   // AF 0.4 -> 0.8, pump-rounded
        // Volatile high: no licence.
        input.algorithmExperiments = AlgorithmExperiments(calmHighLicence: .init(maxVolatility: 0.5))
        XCTAssertEqual(LoopAlgorithm.run(input: input).recommendation!.automatic!.bolusUnits!, standard, accuracy: 1e-9)
    }

    // MARK: - Negative insulin damper

    func testNegativeInsulinDamperDampsRisesOnly() {
        let now = Date()
        // Three hours of suspended basal (scheduled 1 U/h) ending 20 min ago: negative insulin pushing glucose up.
        let suspend = BasalRelativeDose(type: .basal(scheduledRate: 1.0), startDate: now.addingTimeInterval(.hours(-3)),
                                        endDate: now.addingTimeInterval(.minutes(-20)), volume: 0)
        let values: [Double] = [120, 130, 140, 135, 145]
        let glucose = values.enumerated().map { PredictedGlucoseValue(startDate: now.addingTimeInterval(.minutes(5 * Double($0.offset))), quantity: .glucose($0.element)) }
        let basal = [AbsoluteScheduleValue(startDate: now.addingTimeInterval(.hours(-10)), endDate: now.addingTimeInterval(.hours(6)), value: 1.0)]
        let isf = [AbsoluteScheduleValue(startDate: now.addingTimeInterval(.hours(-10)), endDate: now.addingTimeInterval(.hours(6)), value: LoopQuantity.glucose(50))]
        let damped = LoopAlgorithm.negativeInsulinDamped(glucose, damper: .init(), dosesRelativeToBasal: [suspend], basal: basal,
                                                         sensitivity: isf, insulinModel: ExponentialInsulinModelPreset.rapidActingAdult)
        let d = damped.map { $0.quantity.doubleValue(for: unit) }
        XCTAssertEqual(d[0], 120, accuracy: 1e-9)
        XCTAssertLessThan(d[1] - d[0], 10)                       // rise damped
        XCTAssertEqual(d[3] - d[2], -5, accuracy: 1e-9)          // fall kept whole
        // No negative insulin: unchanged.
        let none = LoopAlgorithm.negativeInsulinDamped(glucose, damper: .init(), dosesRelativeToBasal: [], basal: basal,
                                                       sensitivity: isf, insulinModel: ExponentialInsulinModelPreset.rapidActingAdult)
        XCTAssertEqual(none.map { $0.quantity.doubleValue(for: unit) }, values)
    }

    // MARK: - Codable

    func testExperimentsRoundTrip() throws {
        let stack = AlgorithmExperiments.stack(medianVolatility: 5.0)
        let data = try JSONEncoder().encode(stack)
        XCTAssertEqual(try JSONDecoder().decode(AlgorithmExperiments.self, from: data), stack)
        XCTAssertEqual(stack.volatilityBand?.gain, 1.0)          // min(1, 6.7 / 5)
        XCTAssertEqual(AlgorithmExperiments.stack(medianVolatility: 10).volatilityBand!.gain, 0.67, accuracy: 1e-12)
    }
}
