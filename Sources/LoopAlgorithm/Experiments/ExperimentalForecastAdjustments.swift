//
//  ExperimentalForecastAdjustments.swift
//  LoopAlgorithm
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

extension AlgorithmExperiments.PostLowRiseCut {
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

extension AlgorithmExperiments.CalmHighLicence {
    func isActive(currentGlucose: Double, volatility: Double, activeCarbs: Double) -> Bool {
        if carbGate && activeCarbs > 0 { return false }
        return volatility.isFinite && currentGlucose >= minGlucose && volatility <= maxVolatility
    }
}

extension LoopAlgorithm {

    /// Applies the forecast-side experiments, in order: negative insulin damper, then volatility band.
    /// Returns `prediction.glucose` unchanged when neither is enabled.
    public static func applyExperimentalForecastAdjustments<CarbType: CarbEntry>(
        to prediction: LoopPrediction<CarbType>,
        experiments: AlgorithmExperiments,
        volatility: Double?,
        basal: [AbsoluteScheduleValue<Double>],
        sensitivity: [AbsoluteScheduleValue<LoopQuantity>],
        insulinModel: InsulinModel
    ) -> [PredictedGlucoseValue] {
        var glucose = prediction.glucose
        if let damper = experiments.negativeInsulinDamper {
            glucose = negativeInsulinDamped(glucose, damper: damper, dosesRelativeToBasal: prediction.dosesRelativeToBasal,
                                            basal: basal, sensitivity: sensitivity, insulinModel: insulinModel)
        }
        if let band = experiments.volatilityBand, let volatility,
           !(band.carbGate && (prediction.activeCarbs ?? 0) > 0) {
            glucose = volatilityBanded(glucose, band: band, volatility: volatility)
        }
        return glucose
    }

    static func volatilityBanded(_ glucose: [PredictedGlucoseValue], band: AlgorithmExperiments.VolatilityBand,
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

    /// Port of the Loop and Learn Negative Insulin Damper (LoopDataManager.computeNegativeInsulinDamper).
    static func negativeInsulinDamped(_ glucose: [PredictedGlucoseValue], damper: AlgorithmExperiments.NegativeInsulinDamper,
                                      dosesRelativeToBasal: [BasalRelativeDose], basal: [AbsoluteScheduleValue<Double>],
                                      sensitivity: [AbsoluteScheduleValue<LoopQuantity>], insulinModel: InsulinModel) -> [PredictedGlucoseValue] {
        let unit = LoopUnit.milligramsPerDeciliter
        guard let anchorDate = glucose.first?.startDate else { return glucose }
        let cutoff = anchorDate.addingTimeInterval(-damper.lag)

        // Doses as of `lag` ago: later doses dropped, basal deliveries clipped at the cutoff (net units pro-rated),
        // boluses kept whole.
        var lagged: [BasalRelativeDose] = []
        for dose in dosesRelativeToBasal where dose.startDate < cutoff {
            if case .bolus = dose.type { lagged.append(dose); continue }
            if dose.endDate <= cutoff { lagged.append(dose); continue }
            var clipped = dose
            let full = dose.endDate.timeIntervalSince(dose.startDate)
            clipped.endDate = cutoff
            clipped.volume = full > 0 ? dose.volume * cutoff.timeIntervalSince(dose.startDate) / full : dose.volume
            lagged.append(clipped)
        }
        let effects = lagged.glucoseEffects(insulinSensitivityHistory: sensitivity, from: anchorDate.addingTimeInterval(-.minutes(5)))
        var positiveSum = 0.0
        if effects.count > 1 {
            for i in 1..<effects.count {
                positiveSum += Swift.max(0, effects[i].quantity.doubleValue(for: unit) - effects[i - 1].quantity.doubleValue(for: unit))
            }
        }
        guard let isf = sensitivity.closestPrior(to: anchorDate)?.value.doubleValue(for: unit),
              let basalRate = basal.closestPrior(to: anchorDate)?.value else { return glucose }
        let anchorPoint = 0.8 * peakActivity(of: insulinModel).hours * basalRate * isf
        guard anchorPoint > 0 else { return glucose }      // a 0 U/h basal segment disables the damper

        let a0 = damper.anchorAlpha, ms = damper.marginalSlope
        let lin = (1.0 - a0) / anchorPoint
        let tp = (1 - ms) / (2 * lin)
        let alpha: Double
        if positiveSum < tp {
            alpha = 1 - lin * positiveSum
        } else {
            let tv = (1 - lin * tp) * tp
            alpha = (tv + ms * (positiveSum - tp)) / positiveSum
        }
        let damping = Swift.max(0, 1 - Swift.max(ms, alpha))
        guard damping > 0 else { return glucose }

        let keep = 1 - damping
        var damped: [PredictedGlucoseValue] = []
        damped.reserveCapacity(glucose.count)
        var value = 0.0
        for (i, point) in glucose.enumerated() {
            let x = point.quantity.doubleValue(for: unit)
            if i == 0 { value = x; damped.append(point); continue }
            let delta = x - glucose[i - 1].quantity.doubleValue(for: unit)
            value += delta > 0 ? keep * delta : delta
            damped.append(PredictedGlucoseValue(startDate: point.startDate, quantity: LoopQuantity(unit: unit, doubleValue: value)))
        }
        return damped
    }

    static func peakActivity(of model: InsulinModel) -> TimeInterval {
        if let preset = model as? ExponentialInsulinModelPreset { return preset.peakActivity }
        if let exponential = model as? ExponentialInsulinModel { return exponential.peakActivityTime }
        return .minutes(75)
    }
}
