//
//  AlgorithmExperiments.swift
//  LoopAlgorithm
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// Optional, off-by-default algorithm experiments.
///
/// Each experiment is a candidate change that was evaluated in LoopEval (closed-loop counterfactual
/// replay of real CGM and insulin data). They exist so the candidates can be run for testing in real
/// apps. **None of them changes behavior unless it is explicitly enabled**: with `AlgorithmExperiments.none`
/// (the default everywhere) every code path below is skipped and LoopAlgorithm produces exactly the
/// standard forecast and dose.
///
/// The experiments, and the LoopEval candidate each one implements:
///
/// | Property | LoopEval | What it does |
/// |---|---|---|
/// | `retrospectiveCorrectionDropScale` / `...RiseScale` | C01 (with IRC on) | Weight the falling (sensitivity) side of retrospective correction differently from the rising side |
/// | `integralRetrospectiveCorrectionMaxVelocity` | part of C01 as scored | Cap on how fast integral RC may bend the forecast |
/// | `postLowRiseCut` | C20 | After a low, treat an unexplained rise as transient until glucose proves it is a real high |
/// | `volatilityBand` | C29 | Lower the near-term forecast by the recent volatility of glucose, so the low guard sees it |
/// | `calmHighLicence` | C23 / C25 | A high with low volatility and no carbs on board takes a larger automatic-bolus application factor |
/// | `negativeInsulinDamper` | C37 | Damp forecast rises while the recent insulin effect is pushing glucose up (negative insulin) |
///
/// The LoopEval "deployable stack" (C30) is `volatilityBand` + `calmHighLicence` + `postLowRiseCut`
/// together, with per-person constants; see `AlgorithmExperiments.stack(...)`.
public struct AlgorithmExperiments: Codable, Equatable, Sendable {

    /// Multiplier on the retrospective-correction effect when the current discrepancy is negative
    /// (glucose falling faster than predicted). Applies to standard and integral RC. 1.0 = standard.
    public var retrospectiveCorrectionDropScale: Double

    /// Multiplier on the retrospective-correction effect when the current discrepancy is positive
    /// (glucose rising faster than predicted). Applies to standard and integral RC. 1.0 = standard.
    public var retrospectiveCorrectionRiseScale: Double

    /// Ceiling on the integral-RC correction rate, in mg/dL per minute. nil = no ceiling (standard).
    /// Only used when integral retrospective correction is enabled.
    public var integralRetrospectiveCorrectionMaxVelocity: Double?

    public var postLowRiseCut: PostLowRiseCut?
    public var volatilityBand: VolatilityBand?
    public var calmHighLicence: CalmHighLicence?
    public var negativeInsulinDamper: NegativeInsulinDamper?

    public init(
        retrospectiveCorrectionDropScale: Double = 1.0,
        retrospectiveCorrectionRiseScale: Double = 1.0,
        integralRetrospectiveCorrectionMaxVelocity: Double? = nil,
        postLowRiseCut: PostLowRiseCut? = nil,
        volatilityBand: VolatilityBand? = nil,
        calmHighLicence: CalmHighLicence? = nil,
        negativeInsulinDamper: NegativeInsulinDamper? = nil
    ) {
        self.retrospectiveCorrectionDropScale = retrospectiveCorrectionDropScale
        self.retrospectiveCorrectionRiseScale = retrospectiveCorrectionRiseScale
        self.integralRetrospectiveCorrectionMaxVelocity = integralRetrospectiveCorrectionMaxVelocity
        self.postLowRiseCut = postLowRiseCut
        self.volatilityBand = volatilityBand
        self.calmHighLicence = calmHighLicence
        self.negativeInsulinDamper = negativeInsulinDamper
    }

    /// No experiments: standard LoopAlgorithm.
    public static let none = AlgorithmExperiments()

    /// True when no experiment is enabled.
    public var isNone: Bool { self == .none }

    var needsVolatility: Bool { volatilityBand != nil || calmHighLicence != nil }

    /// C01, asymmetric integral RC, as scored in LoopEval. Use together with
    /// `useIntegralRetrospectiveCorrection = true`.
    public static let asymmetricIntegralRC = AlgorithmExperiments(
        retrospectiveCorrectionDropScale: 1.5,
        retrospectiveCorrectionRiseScale: 0.5,
        integralRetrospectiveCorrectionMaxVelocity: 4.0
    )

    /// C30, the LoopEval deployable stack. `medianVolatility` is the person's own median of
    /// `GlucoseVolatility.sigma5` (mg/dL per 5 min) over the last few weeks; LoopEval found 4 weeks
    /// of history sufficient (9 % drift).
    public static func stack(medianVolatility: Double) -> AlgorithmExperiments {
        AlgorithmExperiments(
            postLowRiseCut: PostLowRiseCut(),
            volatilityBand: VolatilityBand(gain: Swift.min(1.0, 6.7 / Swift.max(medianVolatility, 1e-6))),
            calmHighLicence: CalmHighLicence(maxVolatility: medianVolatility)
        )
    }
}

extension AlgorithmExperiments {

    /// C20: post-low-gated RC rise-cut. Within `window` of a glucose reading below `lowThreshold`,
    /// and while current glucose is below `releaseGlucose`, the rising side of retrospective
    /// correction is scaled by `riseScale` (replacing `retrospectiveCorrectionRiseScale`). The
    /// rebound after a low is mostly rescue carbs and counter-regulation, not a lasting need for
    /// insulin; above `releaseGlucose` the high is treated as real and RC is normal.
    public struct PostLowRiseCut: Codable, Equatable, Sendable {
        public var riseScale: Double
        public var window: TimeInterval
        public var lowThreshold: Double        // mg/dL
        public var releaseGlucose: Double      // mg/dL

        public init(riseScale: Double = 0.3, window: TimeInterval = 720 * 60,
                    lowThreshold: Double = 70, releaseGlucose: Double = 180) {
            self.riseScale = riseScale
            self.window = window
            self.lowThreshold = lowThreshold
            self.releaseGlucose = releaseGlucose
        }
    }

    /// C29: volatility-widened lower forecast. Each predicted point τ minutes ahead is lowered by
    /// `gain × σ5 × (τ/5)^exponent` up to `horizon`, tapering to zero by `taperEnd`. Eventual glucose is
    /// untouched; the predicted minimum, which drives the low guard and suspends, sees the volatility.
    /// With `carbGate`, the band is off while carbs are on board.
    public struct VolatilityBand: Codable, Equatable, Sendable {
        public var gain: Double
        public var horizon: TimeInterval
        public var taperEnd: TimeInterval
        public var exponent: Double
        public var carbGate: Bool

        public init(gain: Double, horizon: TimeInterval = 60 * 60, taperEnd: TimeInterval = 120 * 60,
                    exponent: Double = 0.71, carbGate: Bool = true) {
            self.gain = gain
            self.horizon = horizon
            self.taperEnd = taperEnd
            self.exponent = exponent
            self.carbGate = carbGate
        }
    }

    /// C23 / C25: calm-high licence. When current glucose is at or above `minGlucose`, recent
    /// volatility σ5 is at or below `maxVolatility` (the person's own median), and (with `carbGate`)
    /// no carbs are on board, the automatic-bolus application factor is multiplied by
    /// `applicationFactorScale`, capped at 1. Only affects the automatic-bolus dosing strategy.
    public struct CalmHighLicence: Codable, Equatable, Sendable {
        public var applicationFactorScale: Double
        public var minGlucose: Double          // mg/dL
        public var maxVolatility: Double       // mg/dL per 5 min
        public var carbGate: Bool

        public init(applicationFactorScale: Double = 2.0, minGlucose: Double = 180,
                    maxVolatility: Double, carbGate: Bool = true) {
            self.applicationFactorScale = applicationFactorScale
            self.minGlucose = minGlucose
            self.maxVolatility = maxVolatility
            self.carbGate = carbGate
        }
    }

    /// C37: Negative Insulin Damper (Loop and Learn customization). The glucose effect of insulin
    /// delivered up to `lag` ago is summed over its upward steps (the push from negative insulin,
    /// i.e. delivery below scheduled basal); the larger that push relative to an anchor of
    /// 0.8 × peak activity time × basal × ISF, the more forecast rises are damped.
    public struct NegativeInsulinDamper: Codable, Equatable, Sendable {
        public var anchorAlpha: Double
        public var marginalSlope: Double
        public var lag: TimeInterval

        public init(anchorAlpha: Double = 0.75, marginalSlope: Double = 0.05, lag: TimeInterval = 15 * 60) {
            self.anchorAlpha = anchorAlpha
            self.marginalSlope = marginalSlope
            self.lag = lag
        }
    }
}
