//
//  AsymmetricHighCorrection.swift
//  LoopAlgorithm
//
//  Rise-only forecast BG-addition. When there is a PERSISTENT positive retrospective
//  discrepancy (observed glucose rising faster than insulin+carb models predict =
//  unannounced carbs / resistance), add a positive (BG-raising) glucose effect so Loop
//  forecasts higher and doses more. The distinguishing feature vs IRC's rise side:
//  it TURNS OFF FAST when the recent glucose trajectory turns DOWN (a velocity gate),
//  so dosing stops pushing IOB the moment BG starts falling — avoiding overshoot into
//  lows (same spirit as asymmetric momentum). Forecast-side per AGENTS.md §2.
//
//  Mirrors IntegralRetrospectiveCorrection's decayEffect structure: a proportional +
//  persistence-integral correction over the recent same-sign POSITIVE discrepancy run,
//  scaled by riseGain and the fast-off gate, emitted as a decaying glucose effect.
//

import Foundation

public class AsymmetricHighCorrection {
    public static let retrospectionInterval = TimeInterval(minutes: 180)

    let effectDuration: TimeInterval
    /// Overall scale on the rise-side BG-addition (1.0 ~ IRC-strength proportional+integral).
    let riseGain: Double
    /// Fast-off gate: the gate ramps linearly from 1 (recent velocity >= 0) to 0 as the
    /// recent glucose velocity falls to `-fastOffVelocity` mg/dL/min, and stays 0 below.
    /// Smaller value => turns off on a gentler downtrend (more aggressive fast-off).
    let fastOffVelocity: Double

    public var totalGlucoseCorrectionEffect: LoopQuantity?
    private let unit = LoopUnit.milligramsPerDeciliter

    // Persistence integral (mirrors IRC): builds the effect up as a high persists.
    static let delta = TimeInterval(minutes: 5.0)
    static let correctionTimeConstant = TimeInterval(minutes: 60.0)
    static let currentDiscrepancyGain: Double = 1.0
    static let persistentDiscrepancyGain: Double = 2.0
    static let integralForget: Double = exp(-delta.minutes / correctionTimeConstant.minutes)
    static let integralGain: Double = ((1 - integralForget) / integralForget) *
        (persistentDiscrepancyGain - currentDiscrepancyGain)
    static let proportionalGain: Double = currentDiscrepancyGain - integralGain

    public init(effectDuration: TimeInterval, riseGain: Double = 1.0, fastOffVelocity: Double = 0.5) {
        self.effectDuration = effectDuration
        self.riseGain = riseGain
        self.fastOffVelocity = fastOffVelocity
    }

    /// - parameter recentVelocity: recent glucose trend in mg/dL/min (>=0 rising/flat, <0 falling)
    public func computeEffect(
        startingAt startingGlucose: GlucoseValue,
        retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?,
        recencyInterval: TimeInterval,
        retrospectiveCorrectionGroupingInterval: TimeInterval,
        recentVelocity: Double
    ) -> [GlucoseEffect] {
        let glucoseDate = startingGlucose.startDate
        guard let currentDiscrepancy = retrospectiveGlucoseDiscrepanciesSummed?.last,
              glucoseDate.timeIntervalSince(currentDiscrepancy.endDate) <= recencyInterval
        else {
            totalGlucoseCorrectionEffect = nil
            return []
        }
        let currentValue = currentDiscrepancy.quantity.doubleValue(for: unit)
        // Rise-side only — the low side is handled by a separate mechanism.
        guard currentValue > 0 else {
            totalGlucoseCorrectionEffect = nil
            return []
        }

        // Integrate the recent contiguous POSITIVE discrepancy run (persistence).
        var recent: [Double] = []
        if let past = retrospectiveGlucoseDiscrepanciesSummed?.filterDateRange(
            glucoseDate.addingTimeInterval(-Self.retrospectionInterval), glucoseDate) {
            var nextDiscrepancy = currentDiscrepancy
            for p in past.reversed() {
                let pv = p.quantity.doubleValue(for: unit)
                if pv > 0 && nextDiscrepancy.endDate.timeIntervalSince(p.endDate) <= recencyInterval && pv >= 0.1 {
                    recent.append(pv); nextDiscrepancy = p
                } else { break }
            }
            recent = recent.reversed()
        }
        var integral = 0.0
        for v in recent { integral = Self.integralForget * integral + Self.integralGain * v }
        let proportional = Self.proportionalGain * currentValue
        var correction = max(0.0, proportional + integral)

        // Fast-off gate on a downtrend.
        let gate: Double = recentVelocity >= 0 ? 1.0 : max(0.0, 1.0 + recentVelocity / fastOffVelocity)
        correction *= riseGain * gate

        totalGlucoseCorrectionEffect = LoopQuantity(unit: unit, doubleValue: correction)
        if correction <= 0 { return [] }

        let discrepancyTime = max(
            currentDiscrepancy.endDate.timeIntervalSince(currentDiscrepancy.startDate),
            retrospectiveCorrectionGroupingInterval)
        let velocity = LoopQuantity(unit: .milligramsPerDeciliterPerSecond,
                                    doubleValue: correction / discrepancyTime)
        return startingGlucose.decayEffect(atRate: velocity, for: effectDuration)
    }
}
