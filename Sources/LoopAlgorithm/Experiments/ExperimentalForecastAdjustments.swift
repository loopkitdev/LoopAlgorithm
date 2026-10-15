//
//  ExperimentalForecastAdjustments.swift
//  LoopAlgorithm
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

extension ExperimentParameters.PostLowRiseCut {
    /// True when current glucose is below `releaseGlucose` and some reading within `window` before it
    /// was below `lowThreshold`.
    func isActive<GlucoseType: GlucoseValue>(glucoseHistory: [GlucoseType]) -> Bool {
        let unit = LoopUnit.milligramsPerDeciliter
        guard let latest = glucoseHistory.last,
              latest.quantity.doubleValue(for: unit) < releaseGlucose else { return false }
        for sample in glucoseHistory.reversed() {
            if latest.startDate.timeIntervalSince(sample.startDate) > window { break }
            if sample.quantity.doubleValue(for: unit) < lowThreshold { return true }
        }
        return false
    }
}

extension ExperimentParameters.CalmHighLicence {
    func isActive(currentGlucose: Double, volatility: Double, activeCarbs: Double) -> Bool {
        if carbGate && activeCarbs > 0 { return false }
        return volatility.isFinite && currentGlucose >= minGlucose && volatility <= maxVolatility
    }
}

extension LoopAlgorithm {

    /// The volatility band: each predicted point τ minutes ahead is lowered by
    /// `gain × σ5 × (τ/5)^exponent` up to `horizon`, tapering to zero by `taperEnd`.
    static func volatilityBanded(_ glucose: [PredictedGlucoseValue], band: ExperimentParameters.VolatilityBand,
                                 volatility: Double) -> [PredictedGlucoseValue] {
        guard band.gain > 0, let t0 = glucose.first?.startDate else { return glucose }
        let unit = LoopUnit.milligramsPerDeciliter
        let horizon = band.horizon.minutes
        let taperEnd = Swift.max(band.taperEnd.minutes, horizon + 1)
        let atHorizon = pow(Swift.max(horizon, 5.0) / 5.0, band.exponent)
        return glucose.map { point in
            let tau = point.startDate.timeIntervalSince(t0).minutes
            var shape = 0.0
            if tau <= 0 { shape = 0 }
            else if tau <= horizon { shape = pow(Swift.max(tau, 5.0) / 5.0, band.exponent) }
            else if tau < taperEnd { shape = atHorizon * (taperEnd - tau) / (taperEnd - horizon) }
            let offset = -band.gain * volatility * shape
            return PredictedGlucoseValue(startDate: point.startDate,
                                         quantity: LoopQuantity(unit: unit, doubleValue: point.quantity.doubleValue(for: unit) + offset))
        }
    }
}
