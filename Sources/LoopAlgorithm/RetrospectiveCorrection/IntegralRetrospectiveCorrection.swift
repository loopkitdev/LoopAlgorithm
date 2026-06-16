//
//  IntegralRetrospectiveCorrection.swift
//  Loop
//
//  Created by Dragan Maksimovic on 9/19/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation

/**
    Integral Retrospective Correction (IRC) calculates a correction effect in glucose prediction based on a timeline of past discrepancies between observed glucose movement and movement expected based on insulin and carb models. Integral retrospective correction acts as a proportional-integral-differential (PID) controller aimed at reducing modeling errors in glucose prediction.
 
    In the above summary, "discrepancy" is a difference between the actual glucose and the model predicted glucose over retrospective correction grouping interval (set to 30 min in LoopSettings), whereas "past discrepancies" refers to a timeline of discrepancies computed over retrospective correction integration interval (set to 180 min in Loop Settings).
 
 */
public class IntegralRetrospectiveCorrection: RetrospectiveCorrection {
    public static let retrospectionInterval = TimeInterval(minutes: 180)

    /// RetrospectiveCorrection protocol variables
    /// Standard effect duration
    let effectDuration: TimeInterval
    /// Asymmetric correction gains (default 1.0 == standard symmetric IRC).
    /// `dropGainScale` multiplies the correction when the current discrepancy run
    /// is negative (observed BG dropping faster than the model predicted =
    /// sensitivity); `riseGainScale` when positive (resistance). Set
    /// dropGainScale > 1 / riseGainScale < 1 to respond more strongly to drops
    /// (lows-protective) than to rises.
    let dropGainScale: Double
    let riseGainScale: Double
    /// Carry-negative-memory ("remember the low"). When > 0 and the current
    /// discrepancy run is POSITIVE (a rebound), the integral continues back
    /// across the sign flip through the immediately-preceding NEGATIVE run
    /// (the low) instead of resetting at the flip. Those negative discrepancies
    /// are scaled by `lowMemoryScale` and integrated first, so they decay
    /// (via `integralForget`) into the rebound and offset its upward push.
    /// One-sided: a positive run is never carried into a drop. 0 == off
    /// (standard sign-contiguous reset). Typical: 0.5–1.0.
    let lowMemoryScale: Double
    /// Asymmetric PERSISTENCE ("remember the low longer than the high"). Scales how
    /// long the correction lingers in the forecast by the sign of the current
    /// discrepancy run. `dropDurationScale` > 1 makes a NEGATIVE-discrepancy
    /// (sensitivity) correction turn off SLOWLY / persist; `riseDurationScale` < 1
    /// makes a POSITIVE-discrepancy (resistance) correction turn off FAST. The total
    /// correction magnitude is preserved (area-normalized) — only its temporal shape
    /// changes. Defaults 1.0/1.0 reduce to standard IRC.
    let dropDurationScale: Double
    let riseDurationScale: Double
    /// Overall retrospective correction effect
    public var totalGlucoseCorrectionEffect: LoopQuantity?
    
    /**
     Integral retrospective correction parameters:
     - currentDiscrepancyGain: Standard retrospective correction gain
     - persistentDiscrepancyGain: Gain for persistent long-term modeling errors, must be greater than or equal to currentDiscrepancyGain
     - correctionTimeConstant: How fast integral effect accumulates in response to persistent errors
     - differentialGain: Differential effect gain
     - delta: Glucose sampling time interval (5 min)
     - maximumCorrectionEffectDuration: Maximum duration of the correction effect in glucose prediction
     - retrospectiveCorrectionIntegrationInterval: Maximum duration over which to integrate retrospective correction changes
    */
    static let currentDiscrepancyGain: Double = 1.0
    static let persistentDiscrepancyGain: Double = 2.0 // was 5.0
    static let correctionTimeConstant: TimeInterval = TimeInterval(minutes: 60.0) // was 90.0
    static let differentialGain: Double = 2.0
    static let delta: TimeInterval = TimeInterval(minutes: 5.0)
    static let maximumCorrectionEffectDuration: TimeInterval = TimeInterval(minutes: 180.0) // was 240.0
    
    /// Initialize computed integral retrospective correction parameters
    static let integralForget: Double = exp( -delta.minutes / correctionTimeConstant.minutes )
    static let integralGain: Double = ((1 - integralForget) / integralForget) *
        (persistentDiscrepancyGain - currentDiscrepancyGain)
    static let proportionalGain: Double = currentDiscrepancyGain - integralGain

    /// Default ceiling on the RC correction rate. Bounds how fast the integral RC may bend
    /// the forecast, so a large or spurious sustained discrepancy can't wind the correction
    /// up into over-/under-dosing. Chosen at the top of physiologically-plausible *sustained*
    /// unmodeled glucose velocity (~4 mg/dL/min); unlike a bound scaled by ISF/basal/target,
    /// it does not depend on the user's dosing settings — the plausible velocity of unmodeled
    /// physiology is the same regardless of a person's insulin needs or target range.
    public static let defaultMaxCorrectionVelocity = LoopQuantity(
        unit: .milligramsPerDeciliterPerSecond, doubleValue: 4.0 / 60.0)

    /// Ceiling applied to the correction rate (see `defaultMaxCorrectionVelocity`); nil disables it.
    public let maxCorrectionVelocity: LoopQuantity?

    /// All math is performed with glucose expressed in mg/dL
    private let unit = LoopUnit.milligramsPerDeciliter

    /// State variables reported in diagnostic issue report
    var recentDiscrepancyValues: [Double] = []
    var integralCorrectionEffectDuration: TimeInterval?
    var proportionalCorrection: Double = 0.0
    var integralCorrection: Double = 0.0
    var differentialCorrection: Double = 0.0
    /// Correction rate actually used (after the `maxCorrectionVelocity` clamp), for diagnostics.
    var correctionVelocity: LoopQuantity?
    var currentDate: Date = Date()

    public init(effectDuration: TimeInterval,
                dropGainScale: Double = 1.0, riseGainScale: Double = 1.0,
                lowMemoryScale: Double = 0.0,
                dropDurationScale: Double = 1.0, riseDurationScale: Double = 1.0,
                maxCorrectionVelocity: LoopQuantity? = IntegralRetrospectiveCorrection.defaultMaxCorrectionVelocity) {
        self.effectDuration = effectDuration
        self.dropGainScale = dropGainScale
        self.riseGainScale = riseGainScale
        self.lowMemoryScale = lowMemoryScale
        self.dropDurationScale = dropDurationScale
        self.riseDurationScale = riseDurationScale
        self.maxCorrectionVelocity = maxCorrectionVelocity
    }
    
    /**
     Calculates overall correction effect based on timeline of discrepancies, and updates glucoseCorrectionEffect
     
     - Parameters:
     - glucose: Most recent glucose
     - retrospectiveGlucoseDiscrepanciesSummed: Timeline of past discepancies
     
     - Returns:
     - totalRetrospectiveCorrection: Overall glucose effect
     */
    public func computeEffect(
        startingAt startingGlucose: GlucoseValue,
        retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?,
        recencyInterval: TimeInterval,
        retrospectiveCorrectionGroupingInterval: TimeInterval
        ) -> [GlucoseEffect] {
        
        // Loop settings relevant for calculation of effect limits
        // let settings = UserDefaults.appGroup?.loopSettings ?? LoopSettings()
        currentDate = Date()
        
        // Last discrepancy should be recent, otherwise clear the effect and return
        let glucoseDate = startingGlucose.startDate
        var glucoseCorrectionEffect: [GlucoseEffect] = []
        guard let currentDiscrepancy = retrospectiveGlucoseDiscrepanciesSummed?.last,
            glucoseDate.timeIntervalSince(currentDiscrepancy.endDate) <= recencyInterval
            else {
                totalGlucoseCorrectionEffect = nil
                return( [] )
        }
        
        // Default values if we are not able to calculate integral retrospective correction
        let currentDiscrepancyValue = currentDiscrepancy.quantity.doubleValue(for: unit)
        var scaledCorrection = currentDiscrepancyValue
        totalGlucoseCorrectionEffect = LoopQuantity(unit: unit, doubleValue: currentDiscrepancyValue)
        integralCorrectionEffectDuration = effectDuration
        
        // Calculate integral retrospective correction if past discrepancies over integration interval are available and if user settings are available
        if let pastDiscrepancies = retrospectiveGlucoseDiscrepanciesSummed?.filterDateRange(glucoseDate.addingTimeInterval(-Self.retrospectionInterval), glucoseDate) {

            // To reduce response delay, integral retrospective correction is computed over an array of recent contiguous discrepancy values having the same sign as the latest discrepancy value
            recentDiscrepancyValues = []
            var nextDiscrepancy = currentDiscrepancy
            let currentDiscrepancySign = currentDiscrepancy.quantity.doubleValue(for: unit).sign
            // Low-memory carry: when the current run is POSITIVE (a rebound) and
            // lowMemoryScale > 0, after the positive run we continue back through the
            // immediately-preceding NEGATIVE run (the low) rather than resetting at
            // the sign flip — so the low's memory carries into the rebound and offsets
            // its upward push. One-sided (only +run carries a preceding -run).
            let carryLowMemory = lowMemoryScale > 0 && currentDiscrepancySign == FloatingPointSign.plus
            // The low's memory should survive a CGM gap: the positive rebound run keeps
            // the normal recencyInterval hole-tolerance (don't over-extend gappy non-low
            // rebounds), but reaching back INTO the low (and collecting it) may bridge any
            // gap within the retrospection window — a sensor dropout during the low must
            // not erase it. integralForget still down-weights an older low naturally.
            let carryGapTolerance = Self.retrospectionInterval
            var inCarryPhase = false
            for pastDiscrepancy in pastDiscrepancies.reversed() {
                let pastDiscrepancyValue = pastDiscrepancy.quantity.doubleValue(for: unit)
                guard abs(pastDiscrepancyValue) >= 0.1 else { break }
                let gap = nextDiscrepancy.endDate.timeIntervalSince(pastDiscrepancy.endDate)
                if !inCarryPhase {
                    if pastDiscrepancyValue.sign == currentDiscrepancySign {
                        guard gap <= recencyInterval else { break }   // rebound run: normal hole-tolerance
                        recentDiscrepancyValues.append(pastDiscrepancyValue)
                        nextDiscrepancy = pastDiscrepancy
                    } else if carryLowMemory && pastDiscrepancyValue.sign == FloatingPointSign.minus && gap <= carryGapTolerance {
                        inCarryPhase = true   // sign flipped (+ -> -): begin remembering the low, bridging any gap
                        recentDiscrepancyValues.append(pastDiscrepancyValue * lowMemoryScale)
                        nextDiscrepancy = pastDiscrepancy
                    } else {
                        break
                    }
                } else {
                    // In carry phase: keep collecting the negative (low) run, bridging gaps; stop when it ends.
                    if pastDiscrepancyValue.sign == FloatingPointSign.minus && gap <= carryGapTolerance {
                        recentDiscrepancyValues.append(pastDiscrepancyValue * lowMemoryScale)
                        nextDiscrepancy = pastDiscrepancy
                    } else {
                        break
                    }
                }
            }
            recentDiscrepancyValues = recentDiscrepancyValues.reversed()

            // Integral effect math
            integralCorrection = 0.0
            var integralCorrectionEffectMinutes = effectDuration.minutes - 2.0 * IntegralRetrospectiveCorrection.delta.minutes
            for discrepancy in recentDiscrepancyValues {
                integralCorrection =
                    IntegralRetrospectiveCorrection.integralForget * integralCorrection +
                    IntegralRetrospectiveCorrection.integralGain * discrepancy
                integralCorrectionEffectMinutes += 2.0 * IntegralRetrospectiveCorrection.delta.minutes
            }
            // Asymmetric persistence: stretch/shrink how long the correction lingers
            // in the forecast by the sign of the discrepancy run. dropDurationScale > 1
            // makes a negative-discrepancy (sensitivity) correction "turn off slow /
            // persist"; riseDurationScale < 1 makes a positive-discrepancy (resistance)
            // correction turn off fast. (Magnitude is preserved by the area-normalization
            // at `scaledCorrection` below — only the temporal shape changes.)
            let durationScale = currentDiscrepancyValue < 0 ? dropDurationScale : riseDurationScale
            integralCorrectionEffectMinutes *= durationScale
            // Limit effect duration (cap scales with the drop side so persistence isn't clipped)
            integralCorrectionEffectMinutes = min(integralCorrectionEffectMinutes, IntegralRetrospectiveCorrection.maximumCorrectionEffectDuration.minutes * Swift.max(1.0, durationScale))
            
            // Differential effect math
            var differentialDiscrepancy: Double = 0.0
            if recentDiscrepancyValues.count > 1 {
                let previousDiscrepancyValue = recentDiscrepancyValues[recentDiscrepancyValues.count - 2]
                differentialDiscrepancy = currentDiscrepancyValue - previousDiscrepancyValue
            }
            
            // Overall glucose effect calculated as a sum of propotional, integral and differential effects
            proportionalCorrection = IntegralRetrospectiveCorrection.proportionalGain * currentDiscrepancyValue

	    // Differential effect added only when negative, to avoid upward stacking with momentum, while still mitigating sluggishness of retrospective correction when discrepancies start decreasing
            if differentialDiscrepancy < 0.0 {
                differentialCorrection = IntegralRetrospectiveCorrection.differentialGain * differentialDiscrepancy
            } else {
                differentialCorrection = 0.0
            }

            let totalCorrection = proportionalCorrection + integralCorrection + differentialCorrection
            totalGlucoseCorrectionEffect = LoopQuantity(unit: unit, doubleValue: totalCorrection)
            integralCorrectionEffectDuration = TimeInterval(minutes: integralCorrectionEffectMinutes)
            
            // correction value scaled to account for extended effect duration
            scaledCorrection = totalCorrection * effectDuration.minutes / integralCorrectionEffectDuration!.minutes
        }

        // Asymmetric retrospective correction: scale the correction by the sign
        // of the current (same-sign) discrepancy run. A negative discrepancy means
        // BG dropped faster than the model predicted (sensitivity) -> the correction
        // is negative -> forecast bends down -> Loop doses less / suspends earlier.
        // Amplifying that side (dropGainScale > 1) makes IRC respond faster to
        // sensitivity; damping the rise side (riseGainScale < 1) makes it slower to
        // add insulin on resistance. Defaults 1.0/1.0 reduce to standard IRC.
        scaledCorrection *= (currentDiscrepancyValue < 0 ? dropGainScale : riseGainScale)

        let retrospectionTimeInterval = currentDiscrepancy.endDate.timeIntervalSince(currentDiscrepancy.startDate)
        let discrepancyTime = max(retrospectionTimeInterval, retrospectiveCorrectionGroupingInterval)
        var velocityValue = scaledCorrection / discrepancyTime

        // Bound the correction rate to a settings-free physiological ceiling (see
        // `defaultMaxCorrectionVelocity`), so a large or spurious sustained discrepancy
        // can't wind the integral up into over-/under-dosing.
        if let maxCorrectionVelocity {
            let cap = abs(maxCorrectionVelocity.doubleValue(for: .milligramsPerDeciliterPerSecond))
            velocityValue = min(max(velocityValue, -cap), cap)
        }
        let velocity = LoopQuantity(unit: .milligramsPerDeciliterPerSecond, doubleValue: velocityValue)
        correctionVelocity = velocity

        // Update array of glucose correction effects
        glucoseCorrectionEffect = startingGlucose.decayEffect(atRate: velocity, for: integralCorrectionEffectDuration!)
        
        // Return glucose correction effects
        return( glucoseCorrectionEffect )
    }

}
