//
//  AlgorithmExperiments.swift
//  LoopAlgorithm
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// An optional algorithm experiment. `nil` (the default everywhere) is standard LoopAlgorithm.
///
/// There are deliberately only two, so that people who choose to try one pool into large groups whose
/// results can be compared. Each is a fixed configuration that was evaluated in LoopEval (closed-loop
/// counterfactual replay of real CGM and insulin data, scored against the standard algorithm swept over
/// insulin needs); neither has tunable parameters.
public enum AlgorithmExperiment: String, Codable, CaseIterable, Sendable {

    /// LoopEval C01. Integral retrospective correction (switched on by the experiment, whatever the
    /// integral-RC setting), with the falling side of the correction weighted 1.5× and the rising side
    /// 0.5×, and the correction rate capped at 4 mg/dL per minute. It reacts faster to glucose
    /// running below the forecast and more slowly to glucose running above it.
    case asymmetricIntegralRC

    /// LoopEval C30, three parts that act in different situations:
    /// - **Post-low rise-cut** (C20). For 12 h after a reading below 70 mg/dL, and while glucose is
    ///   below 180, the rising side of retrospective correction is weighted 0.3×: the rebound after a
    ///   low (rescue carbs, counter-regulation) is not treated as a lasting need for insulin.
    /// - **Volatility band** (C29). While no carbs are on board, the first two hours of the forecast are
    ///   lowered in proportion to recent glucose volatility, so the low guard sees it. Eventual glucose
    ///   is unchanged.
    /// - **Calm-high licence** (C23/C25). When glucose is 180 or above, volatility is at or below the
    ///   person's own median and no carbs are on board, the automatic-bolus application factor is
    ///   doubled (capped at 1). Automatic-bolus dosing only.
    ///
    /// The band depth and the licence threshold are keyed to the person's median volatility; supply it
    /// as `AlgorithmInput.volatilityBaseline` (see `GlucoseVolatility.baseline(_:)`).
    case stack
}

/// The internal configuration each experiment expands to. Not public: the experiments are fixed.
struct ExperimentParameters: Equatable {
    var retrospectiveCorrectionDropScale = 1.0
    var retrospectiveCorrectionRiseScale = 1.0
    var integralRetrospectiveCorrectionMaxVelocity: Double? = nil     // mg/dL per minute
    var forceIntegralRetrospectiveCorrection = false
    var postLowRiseCut: PostLowRiseCut? = nil
    var volatilityBand: VolatilityBand? = nil
    var calmHighLicence: CalmHighLicence? = nil

    static let none = ExperimentParameters()

    var needsVolatility: Bool { volatilityBand != nil || calmHighLicence != nil }

    /// `volatilityBaseline` is the person's median σ5 (mg/dL per 5 min); only the stack uses it.
    init(experiment: AlgorithmExperiment?, volatilityBaseline: Double?) {
        switch experiment {
        case nil:
            break
        case .asymmetricIntegralRC:
            retrospectiveCorrectionDropScale = 1.5
            retrospectiveCorrectionRiseScale = 0.5
            integralRetrospectiveCorrectionMaxVelocity = 4.0
            forceIntegralRetrospectiveCorrection = true
        case .stack:
            postLowRiseCut = PostLowRiseCut()
            if let baseline = volatilityBaseline, baseline.isFinite, baseline > 0 {
                volatilityBand = VolatilityBand(gain: Swift.min(1.0, 6.7 / baseline))
                calmHighLicence = CalmHighLicence(maxVolatility: baseline)
            }
        }
    }

    init() {}

    struct PostLowRiseCut: Equatable {
        var riseScale = 0.3
        var window: TimeInterval = .hours(12)
        var lowThreshold = 70.0          // mg/dL
        var releaseGlucose = 180.0       // mg/dL
    }

    struct VolatilityBand: Equatable {
        var gain: Double
        var horizon: TimeInterval = .minutes(60)
        var taperEnd: TimeInterval = .minutes(120)
        var exponent = 0.71
        var carbGate = true
    }

    struct CalmHighLicence: Equatable {
        var applicationFactorScale = 2.0
        var minGlucose = 180.0           // mg/dL
        var maxVolatility: Double        // mg/dL per 5 min
        var carbGate = true
    }
}
