//
//  GlucoseVolatility.swift
//  LoopAlgorithm
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// Causal short-term glucose volatility, used by the `volatilityBand` and `calmHighLicence` experiments.
public enum GlucoseVolatility {

    /// EWMA weight on the previous variance.
    public static let lambda = 0.875
    /// CGM noise level; the variance is floored at 2 × noise².
    public static let noise = 1.4

    /// σ5: the exponentially weighted RMS of the 5-minute glucose increment, in mg/dL per 5 min,
    /// over the last ~5 h of readings. Readings 2–7 min apart contribute (scaled to 5 min); a gap of
    /// more than 7 min restarts the estimate. With no usable pair the floor sqrt(2 × noise²) is returned.
    public static func sigma5<GlucoseType: GlucoseValue>(_ glucoseHistory: [GlucoseType]) -> Double {
        let unit = LoopUnit.milligramsPerDeciliter
        let floorVariance = 2.0 * noise * noise
        var variance = Double.nan
        var previous: (date: Date, value: Double)? = nil
        for sample in glucoseHistory.suffix(60) {
            let value = sample.quantity.doubleValue(for: unit)
            if let previous {
                let minutes = sample.startDate.timeIntervalSince(previous.date) / 60.0
                if minutes > 2.0 && minutes <= 7.0 {
                    let d5 = (value - previous.value) * (5.0 / minutes)
                    variance = variance.isNaN
                        ? Swift.max(d5 * d5, floorVariance)
                        : Swift.max(lambda * variance + (1 - lambda) * d5 * d5, floorVariance)
                } else if minutes > 7.0 {
                    variance = .nan
                }
            }
            previous = (sample.startDate, value)
        }
        return variance.isNaN ? floorVariance.squareRoot() : variance.squareRoot()
    }
}
