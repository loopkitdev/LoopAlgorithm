//
//  StandardRetrospectiveCorrection.swift
//  Loop
//
//  Created by Dragan Maksimovic on 10/27/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation

/**
 Standard Retrospective Correction (RC) calculates a correction effect in glucose prediction based on the most recent discrepancy between observed glucose movement and movement expected based on insulin and carb models. Standard retrospective correction acts as a proportional (P) controller aimed at reducing modeling errors in glucose prediction.
 
 In the above summary, "discrepancy" is a difference between the actual glucose and the model predicted glucose over retrospective correction grouping interval (set to 30 min in LoopSettings)
 */
public class StandardRetrospectiveCorrection: RetrospectiveCorrection {
    /// RetrospectiveCorrection protocol variables
    /// Standard effect duration
    let effectDuration: TimeInterval
    /// Overall retrospective correction effect
    public var totalGlucoseCorrectionEffect: LoopQuantity?

    /// All math is performed with glucose expressed in mg/dL
    private let unit = LoopUnit.milligramsPerDeciliter

    /// Experimental asymmetric gains (see `AlgorithmExperiments`): multiply the correction when the
    /// current discrepancy is negative (drop) or positive (rise). 1.0 / 1.0 is standard RC.
    let dropScale: Double
    let riseScale: Double

    public init(effectDuration: TimeInterval, dropScale: Double = 1.0, riseScale: Double = 1.0) {
        self.effectDuration = effectDuration
        self.dropScale = dropScale
        self.riseScale = riseScale
    }

    public func computeEffect(
        startingAt startingGlucose: GlucoseValue,
        retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?,
        recencyInterval: TimeInterval,
        retrospectiveCorrectionGroupingInterval: TimeInterval
    ) -> [GlucoseEffect] {
        // Last discrepancy should be recent, otherwise clear the effect and return
        let glucoseDate = startingGlucose.startDate
        guard let currentDiscrepancy = retrospectiveGlucoseDiscrepanciesSummed?.last,
            glucoseDate.timeIntervalSince(currentDiscrepancy.endDate) <= recencyInterval
        else {
            totalGlucoseCorrectionEffect = nil
            return []
        }
        
        // Standard retrospective correction math
        var currentDiscrepancyValue = currentDiscrepancy.quantity.doubleValue(for: unit)
        if dropScale != 1.0 || riseScale != 1.0 {
            currentDiscrepancyValue *= currentDiscrepancyValue < 0 ? dropScale : riseScale
        }
        totalGlucoseCorrectionEffect = LoopQuantity(unit: unit, doubleValue: currentDiscrepancyValue)
        
        let retrospectionTimeInterval = currentDiscrepancy.endDate.timeIntervalSince(currentDiscrepancy.startDate)
        let discrepancyTime = max(retrospectionTimeInterval, retrospectiveCorrectionGroupingInterval)
        let velocity = LoopQuantity(unit: .milligramsPerDeciliterPerSecond, doubleValue: currentDiscrepancyValue / discrepancyTime)
        
        // Update array of glucose correction effects
        return startingGlucose.decayEffect(atRate: velocity, for: effectDuration)
    }
}
