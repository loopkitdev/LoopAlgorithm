//
//  LoopAlgorithm.swift
//
//  Created by Pete Schwamb on 6/30/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import Foundation

public enum AlgorithmError: Error {
    case missingGlucose
    case glucoseTooOld
    case basalTimelineIncomplete
    case missingSuspendThreshold
    case sensitivityTimelineStartsTooLate
    case sensitivityTimelineEndsTooEarly
    case futureBasalNotAllowed
}

public struct LoopAlgorithmEffects<CarbStatusType: CarbEntry> {
    public var insulin: [GlucoseEffect]
    public var carbs: [GlucoseEffect]
    public var carbStatus: [CarbStatus<CarbStatusType>]
    public var retrospectiveCorrection: [GlucoseEffect]
    public var momentum: [GlucoseEffect]
    public var insulinCounteraction: [GlucoseEffectVelocity]
    public var retrospectiveGlucoseDiscrepancies: [GlucoseChange]
    public var totalRetrospectiveCorrectionEffect: LoopQuantity?

    public init(
        insulin: [GlucoseEffect],
        carbs: [GlucoseEffect],
        carbStatus: [CarbStatus<CarbStatusType>],
        retrospectiveCorrection: [GlucoseEffect],
        momentum: [GlucoseEffect],
        insulinCounteraction: [GlucoseEffectVelocity],
        retrospectiveGlucoseDiscrepancies: [GlucoseChange],
        totalRetrospectiveCorrectionEffect: LoopQuantity? = nil
    ) {
        self.insulin = insulin
        self.carbs = carbs
        self.carbStatus = carbStatus
        self.retrospectiveCorrection = retrospectiveCorrection
        self.momentum = momentum
        self.insulinCounteraction = insulinCounteraction
        self.retrospectiveGlucoseDiscrepancies = retrospectiveGlucoseDiscrepancies
        self.totalRetrospectiveCorrectionEffect = totalRetrospectiveCorrectionEffect
    }
}

extension LoopAlgorithmEffects<FixtureCarbEntry>: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.insulin = try container.decode([GlucoseEffect].self, forKey: .insulin)
        self.carbs = try container.decode([GlucoseEffect].self, forKey: .carbs)
        self.carbStatus = try container.decode([CarbStatus<FixtureCarbEntry>].self, forKey: .carbStatus)
        self.retrospectiveCorrection = try container.decode([GlucoseEffect].self, forKey: .retrospectiveCorrection)
        self.momentum = try container.decode([GlucoseEffect].self, forKey: .momentum)
        self.insulinCounteraction = try container.decode([GlucoseEffectVelocity].self, forKey: .insulinCounteraction)
        self.retrospectiveGlucoseDiscrepancies = try container.decode([GlucoseChange].self, forKey: .retrospectiveGlucoseDiscrepancies)

        if let totalRetrospectiveCorrectionEffectValue = try container.decodeIfPresent(Double.self, forKey: .totalRetrospectiveCorrectionEffect) {
            self.totalRetrospectiveCorrectionEffect = LoopQuantity(
                unit: .milligramsPerDeciliter,
                doubleValue: totalRetrospectiveCorrectionEffectValue
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(insulin, forKey: .insulin)
        try container.encode(carbs, forKey: .carbs)
        try container.encode(carbStatus, forKey: .carbStatus)
        try container.encode(retrospectiveCorrection, forKey: .retrospectiveCorrection)
        try container.encode(momentum, forKey: .momentum)
        try container.encode(insulinCounteraction, forKey: .insulinCounteraction)
        try container.encode(retrospectiveGlucoseDiscrepancies, forKey: .retrospectiveGlucoseDiscrepancies)
        if let totalRetrospectiveCorrectionEffect {
            try container.encode(
                totalRetrospectiveCorrectionEffect.doubleValue(for: .milligramsPerDeciliter),
                forKey: .totalRetrospectiveCorrectionEffect
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case insulin
        case carbs
        case carbStatus
        case retrospectiveCorrection
        case momentum
        case insulinCounteraction
        case retrospectiveGlucoseDiscrepancies
        case totalRetrospectiveCorrectionEffect
    }
}


public struct AlgorithmEffectsOptions: OptionSet, Sendable {
    public let rawValue: UInt8

    public static let carbs            = AlgorithmEffectsOptions(rawValue: 1 << 0)
    public static let insulin          = AlgorithmEffectsOptions(rawValue: 1 << 1)
    public static let momentum         = AlgorithmEffectsOptions(rawValue: 1 << 2)
    public static let retrospection    = AlgorithmEffectsOptions(rawValue: 1 << 3)

    public static let all: AlgorithmEffectsOptions = [.carbs, .insulin, .momentum, .retrospection]

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

public struct LoopPrediction<CarbStatusType: CarbEntry> {
    public var glucose: [PredictedGlucoseValue]
    public var effects: LoopAlgorithmEffects<CarbStatusType>
    public var dosesRelativeToBasal: [BasalRelativeDose]
    public var activeInsulin: Double?
    public var activeCarbs: Double?

    public init(
        glucose: [PredictedGlucoseValue],
        effects: LoopAlgorithmEffects<CarbStatusType>,
        dosesRelativeToBasal: [BasalRelativeDose] = [],
        activeInsulin: Double? = nil,
        activeCarbs: Double? = nil
    ) {
        self.glucose = glucose
        self.effects = effects
        self.dosesRelativeToBasal = dosesRelativeToBasal
        self.activeInsulin = activeInsulin
        self.activeCarbs = activeCarbs
    }
}

public struct LoopAlgorithm {
    /// Percentage of recommended dose to apply as bolus when using automatic bolus dosing strategy
    static public let defaultBolusPartialApplicationFactor = 0.4

    /// The duration of recommended temp basals
    static public let tempBasalDuration = TimeInterval(minutes: 30)

    /// The amount of time since a given date that input data should be considered valid
    public static let inputDataRecencyInterval = TimeInterval(minutes: 15)

    /// Calculates the needed interval for insulin sensitivity to run the algorithm
    /// - Parameters:
    ///   - doses: The active doses affecting the forecast
    ///   - glucoseHistoryStart: The start date of glucose history
    ///   - recommendationEffectInterval:The interval covering effects of a recommended dose
    public static func timelineIntervalForSensitivity<DoseType: InsulinDose>(
        doses: [DoseType],
        glucoseHistoryStart: Date,
        recommendationEffectInterval: DateInterval
    ) -> DateInterval {
        return (doses.effectsInterval() ?? DateInterval(start: glucoseHistoryStart, end: glucoseHistoryStart))
            .extendedToInclude(glucoseHistoryStart)
            .extendedToInclude(recommendationEffectInterval)
            .extendedForSimulation()
    }

    /// Generates a forecast predicting glucose.
    /// Outputs may be incomplete, if there are issues with the provided data, but as many intermediate derived fields as can be computed, will be computed.
    ///
    /// Returns nil if the normal scheduled basal, or active temporary basal, is sufficient.
    /// 
    ///
    /// - Parameters:
    ///   - start: The starting time of the glucose prediction.
    ///   - glucoseHistory: History of glucose values: t-10h to t. Must include at least one value.
    ///   - doses: History of insulin doses: t-16h to t
    ///   - carbEntries: History of carb entries: t-10h to t
    ///   - basal: Scheduled basal rate timeline: t-16h to t
    ///   - sensitivity: Insulin sensitivity timeline: t-16h to t (eventually with mid-absorption isf changes, it will be t-10h to t)
    ///   - carbRatio: Carb ratio timeline: t-10h to t+6h
    ///   - algorithmEffectsOptions: Which effects to include when combining effects to generate glucose prediction
    ///   - useIntegralRetrospectiveCorrection: If true, the prediction will use Integral Retrospection. If false, will use traditional Retrospective Correction
    ///   - includingPositiveVelocityAndRC: If false, only net negative momentum and RC effects will used.
    ///   - carbAbsorptionModel: A model conforming to CarbAbsorptionComputable that is used for computing carb absorption over time.
    /// - Returns: A LoopPrediction struct containing the predicted glucose and the computed intermediate effects used to make the prediction

    public static func generatePrediction<CarbType, GlucoseType, InsulinDoseType>(
        start: Date,
        glucoseHistory: [GlucoseType],
        doses: [InsulinDoseType],
        carbEntries: [CarbType],
        basal: [AbsoluteScheduleValue<Double>],
        sensitivity: [AbsoluteScheduleValue<LoopQuantity>],
        // Phase 1: optional separate sensitivity schedule for the EGP-credit
        // (negative `netBasalUnits`) glucose-effect term. When nil, `sensitivity`
        // is used for both the active-insulin and EGP-credit components — bit-
        // identical to pre-Phase-1 behavior. When non-nil, callers can boost
        // `sensitivity` (active term: dose-rec sees it; insulin works harder)
        // without amplifying the model's implicit EGP-credit assumption.
        scheduleBaselineSensitivity: [AbsoluteScheduleValue<LoopQuantity>]? = nil,
        // Phase 2: how to split each dose's effect into active-insulin vs
        // EGP-credit. `.netBasalUnits` (default) is the classic sign-split.
        // `.physicalDelivery` splits physical-volume vs scheduled-basal-offset,
        // so a `sensitivity` (active) boost amplifies real insulin even when
        // delivery is below scheduled basal. Only meaningful when
        // `scheduleBaselineSensitivity` differs from `sensitivity`.
        sensitivityDecomposition: SensitivityDecomposition = .netBasalUnits,
        carbRatio: [AbsoluteScheduleValue<Double>],
        // Correction-range timeline — used only to clamp the IntegralRC integral
        // term (deployed-LoopKit safety bound). nil ⇒ IRC clamp skipped (legacy).
        target: GlucoseRangeTimeline? = nil,
        algorithmEffectsOptions: AlgorithmEffectsOptions = .all,
        useIntegralRetrospectiveCorrection: Bool = false,
        // Asymmetric IRC gains (only used when useIntegralRetrospectiveCorrection
        // is true). Default 1.0/1.0 == standard symmetric IRC.
        ircDropGainScale: Double = 1.0,
        ircRiseGainScale: Double = 1.0,
        ircLowMemoryScale: Double = 0.0,
        ircDropDurationScale: Double = 1.0,
        ircRiseDurationScale: Double = 1.0,
        // RC integration window (how far back) / effect duration (how far forward).
        // nil => the deployed static defaults (180 min / 60 min).
        rcRetrospectionInterval: TimeInterval? = nil,
        rcEffectDuration: TimeInterval? = nil,
        // UAM projection: treat recent unexplained glucose appearance (ICE - modeled carbs)
        // as ongoing absorption, projected forward with a linear taper over this many
        // minutes. 0 = off. Continuous mechanism for unannounced meals.
        uamProjectionMinutes: Double = 0,
        // Early-ascending-limb projection (continuous complement of GBAF). Active only when
        // earlyRiseGain > 0 AND earlyRiseMinutes > 0. See earlyRiseProjectionEffects.
        earlyRiseMinutes: Double = 0,
        earlyRiseGain: Double = 0,
        earlyRiseBgLow: Double = 70,
        earlyRiseBgHigh: Double = 140,
        earlyRiseSlopeThreshold: Double = 0.3,
        includingPositiveVelocityAndRC: Bool = true,
        useLegacyRCDecay: Bool = false,
        useMidAbsorptionISF: Bool = false,
        carbAbsorptionModel: CarbAbsorptionComputable = PiecewiseLinearAbsorption(),
        adaptiveCarbAbsorption: Bool = false,
        initialAbsorptionTimeOverrun: Double = CarbMath.defaultAbsorptionTimeOverrun,
        gradualTransitionsThreshold: Double? = 40.0,
        momentumVelocityMaximum: LoopQuantity? = nil,
        momentumProjectionDuration: TimeInterval? = nil,
        // Momentum LOOKBACK: glucose history window the momentum slope is fit over.
        // nil => GlucoseMath.momentumDataInterval (15 min).
        momentumDataInterval: TimeInterval? = nil,
        useAsymmetricMomentum: Bool = false,
        useHybridAsymmetricMomentum: Bool = false,
        momentumAlphaSlow: Double = 0.15,
        momentumAlphaFast: Double = 0.85
    ) -> LoopPrediction<CarbType> where CarbType: CarbEntry, GlucoseType: GlucoseSampleValue, InsulinDoseType: InsulinDose {

        var prediction: [PredictedGlucoseValue] = []
        var insulinEffects: [GlucoseEffect] = []
        var carbEffects: [GlucoseEffect] = []
        var retrospectiveCorrectionEffects: [GlucoseEffect] = []
        var momentumEffects: [GlucoseEffect] = []
        var insulinCounteractionEffects: [GlucoseEffectVelocity] = []
        var retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange] = []
        var totalRetrospectiveCorrectionEffect: LoopQuantity?
        var activeInsulin: Double?
        var activeCarbs: Double?
        //var carbStatus: [CarbStatus] = []
        var dosesRelativeToBasal: [BasalRelativeDose] = []

        // Ensure basal history covers doses
        let doseStart = doses.first?.startDate ?? start
        if !basal.isEmpty, basal.first!.startDate <= doseStart {
            // Overlay basal history on basal doses, splitting doses to get amount delivered relative to basal
            dosesRelativeToBasal = doses.annotated(with: basal)

            activeInsulin = dosesRelativeToBasal.insulinOnBoard(at: start)

            var insulinEffectsInterval = dosesRelativeToBasal.effectsInterval() ?? DateInterval(start: start, end: start)

            // Extend range of insulin effects to cover glucose, if needed
            if let glucoseStart = glucoseHistory.first?.startDate, glucoseStart < insulinEffectsInterval.start {
                insulinEffectsInterval = insulinEffectsInterval.extendedToInclude(glucoseStart)
            }

            if let glucoseEnd = glucoseHistory.last?.endDate, glucoseEnd > insulinEffectsInterval.end {
                insulinEffectsInterval = insulinEffectsInterval.extendedToInclude(glucoseEnd)
            }

            if useMidAbsorptionISF {
                insulinEffects = dosesRelativeToBasal.glucoseEffectsMidAbsorptionISF(
                    insulinSensitivityHistory: sensitivity,
                    scheduleBaselineSensitivityHistory: scheduleBaselineSensitivity,
                    from: insulinEffectsInterval.start,
                    to: insulinEffectsInterval.end,
                    decomposition: sensitivityDecomposition)
            } else {
                insulinEffects = dosesRelativeToBasal.glucoseEffects(
                    insulinSensitivityHistory: sensitivity,
                    scheduleBaselineSensitivityHistory: scheduleBaselineSensitivity,
                    from: insulinEffectsInterval.start,
                    to: insulinEffectsInterval.end,
                    decomposition: sensitivityDecomposition)
            }

            // ICE
            insulinCounteractionEffects = glucoseHistory.counteractionEffects(to: insulinEffects)
        } else {
            activeInsulin = 0
        }

        // Carb Effects
        let carbStatus = carbEntries.map(
            to: insulinCounteractionEffects,
            carbRatio: carbRatio,
            insulinSensitivity: sensitivity,
            initialAbsorptionTimeOverrun: initialAbsorptionTimeOverrun,
            absorptionModel: carbAbsorptionModel,
            adaptiveAbsorptionRateEnabled: adaptiveCarbAbsorption
        )

        carbEffects = carbStatus.dynamicGlucoseEffects(
            from: start.addingTimeInterval(-(rcRetrospectionInterval ?? IntegralRetrospectiveCorrection.retrospectionInterval)),
            carbRatios: carbRatio,
            insulinSensitivities: sensitivity,
            absorptionModel: carbAbsorptionModel
        )

        activeCarbs = carbStatus.dynamicCarbsOnBoard(at: start, absorptionModel: carbAbsorptionModel)

        // RC
        let retrospectiveGlucoseDiscrepancies = insulinCounteractionEffects.subtracting(carbEffects)
        retrospectiveGlucoseDiscrepanciesSummed = retrospectiveGlucoseDiscrepancies.combinedSums(of: LoopMath.retrospectiveCorrectionGroupingInterval * 1.01)

        let rc: RetrospectiveCorrection

        if useIntegralRetrospectiveCorrection {
            rc = IntegralRetrospectiveCorrection(effectDuration: rcEffectDuration ?? LoopMath.retrospectiveCorrectionEffectDuration, dropGainScale: ircDropGainScale, riseGainScale: ircRiseGainScale, lowMemoryScale: ircLowMemoryScale, dropDurationScale: ircDropDurationScale, riseDurationScale: ircRiseDurationScale, integrationInterval: rcRetrospectionInterval, maxEffectDuration: rcEffectDuration, useLegacyDecay: useLegacyRCDecay)
        } else {
            rc = StandardRetrospectiveCorrection(effectDuration: rcEffectDuration ?? LoopMath.retrospectiveCorrectionEffectDuration, useLegacyDecay: useLegacyRCDecay)
        }

        if let latestGlucose = glucoseHistory.last {
            // Inputs for the IntegralRC integral-correction clamp (deployed-LoopKit
            // safety bound). nil target ⇒ clamp skipped (legacy unclamped behavior).
            let clampISF = sensitivity.closestPrior(to: start)?.value
            let clampBasal = basal.closestPrior(to: start)?.value
            let clampRange = target?.closestPrior(to: start)?.value
            retrospectiveCorrectionEffects = rc.computeEffect(
                startingAt: latestGlucose,
                retrospectiveGlucoseDiscrepanciesSummed: retrospectiveGlucoseDiscrepanciesSummed,
                recencyInterval: TimeInterval(minutes: 15),
                insulinSensitivity: clampISF,
                basalRate: clampBasal,
                correctionRange: clampRange,
                retrospectiveCorrectionGroupingInterval: LoopMath.retrospectiveCorrectionGroupingInterval
            )

            totalRetrospectiveCorrectionEffect = rc.totalGlucoseCorrectionEffect

            var effects = [[GlucoseEffect]]()

            if algorithmEffectsOptions.contains(.carbs) {
                effects.append(carbEffects)
            }

            if algorithmEffectsOptions.contains(.insulin) {
                effects.append(insulinEffects)
            }

            // UAM projection: observed unexplained glucose appearance (ICE minus modeled
            // carbs) is treated as ongoing absorption that continues and tapers — a
            // continuous, biological forecast term for unannounced meals.
            if uamProjectionMinutes > 0 {
                let uam = uamProjectionEffects(
                    discrepancies: retrospectiveGlucoseDiscrepancies,
                    start: start,
                    projectionDuration: .minutes(uamProjectionMinutes))
                if !uam.isEmpty { effects.append(uam) }
            }

            // Early-ascending-limb projection (continuous complement of GBAF).
            if earlyRiseGain > 0, earlyRiseMinutes > 0 {
                let er = earlyRiseProjectionEffects(
                    glucoseHistory: glucoseHistory,
                    start: start,
                    projectionDuration: .minutes(earlyRiseMinutes),
                    gain: earlyRiseGain,
                    bgLow: earlyRiseBgLow,
                    bgHigh: earlyRiseBgHigh,
                    slopeThreshold: earlyRiseSlopeThreshold)
                if !er.isEmpty { effects.append(er) }
            }

            if algorithmEffectsOptions.contains(.retrospection) {
                // Check if glucose data is smooth enough for RC
                // Use the same input window as retrospective correction             
                var useRC: Bool = true

                // Don't apply RC if glucose has large jumps
                let rcTransitionData = glucoseHistory.filterDateRange(
                    start.addingTimeInterval(-LoopMath.retrospectiveCorrectionGroupingInterval), 
                    start
                )   

                if let _gtt = gradualTransitionsThreshold, !rcTransitionData.hasGradualTransitions(gradualTransitionThreshold: _gtt) {
                    useRC = false
                }

                // Don't apply positive RC if that setting is disabled
                if !includingPositiveVelocityAndRC, 
                    let netRC = retrospectiveCorrectionEffects.netEffect(), 
                    netRC.quantity.doubleValue(for: .milligramsPerDeciliter) > 0 {
                        useRC = false
                    }
                
                if useRC {
                    effects.append(retrospectiveCorrectionEffects)
                }
            }

            // Glucose Momentum
            var useMomentum: Bool = true
            if algorithmEffectsOptions.contains(.momentum) {
                let momentumInputData = glucoseHistory.filterDateRange(start.addingTimeInterval(-(momentumDataInterval ?? GlucoseMath.momentumDataInterval)), start)
                if useHybridAsymmetricMomentum {
                    momentumEffects = momentumInputData.hybridAsymmetricMomentumEffect(velocityMaximum: momentumVelocityMaximum, alphaFast: momentumAlphaFast)
                } else if useAsymmetricMomentum {
                    momentumEffects = momentumInputData.asymmetricMomentumEffect(velocityMaximum: momentumVelocityMaximum, alphaSlow: momentumAlphaSlow, alphaFast: momentumAlphaFast)
                } else {
                    momentumEffects = momentumInputData.linearMomentumEffect(
                        duration: momentumProjectionDuration ?? GlucoseMath.momentumDuration,
                        velocityMaximum: momentumVelocityMaximum,
                        gradualTransitionsThreshold: gradualTransitionsThreshold)
                }
                if !includingPositiveVelocityAndRC, let netMomentum = momentumEffects.netEffect(), netMomentum.quantity.doubleValue(for: .milligramsPerDeciliter) > 0 {
                    // positive momentum is turned off
                    useMomentum = false
                }
            } else {
                useMomentum = false
            }

            prediction = LoopMath.predictGlucose(
                startingAt: latestGlucose,
                momentum: useMomentum ? momentumEffects : [],
                effects: effects
            )

            // Dosing requires prediction entries at least as long as the insulin model duration.
            // If our prediction is shorter than that, then extend it here.
            let finalDate = start.addingTimeInterval(InsulinMath.defaultInsulinActivityDuration)
            if let last = prediction.last, last.startDate < finalDate {
                prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
            }
        }

        return LoopPrediction(
            glucose: prediction,
            effects: LoopAlgorithmEffects(
                insulin: insulinEffects,
                carbs: carbEffects,
                carbStatus: carbStatus,
                retrospectiveCorrection: retrospectiveCorrectionEffects,
                momentum: momentumEffects,
                insulinCounteraction: insulinCounteractionEffects,
                retrospectiveGlucoseDiscrepancies: retrospectiveGlucoseDiscrepanciesSummed,
                totalRetrospectiveCorrectionEffect: totalRetrospectiveCorrectionEffect
            ),
            dosesRelativeToBasal: dosesRelativeToBasal,
            activeInsulin: activeInsulin,
            activeCarbs: activeCarbs
        )
    }

    /// Generates a forecast using pre-annotated insulin data.
    ///
    /// This overload is optimised for multi-step historical sweeps where the
    /// same dose history is evaluated at many consecutive time points.  By
    /// accepting a `PrecomputedInsulinInput` the caller can:
    ///
    ///   1. **Skip `annotated(with: basal)`** — the most expensive per-step
    ///      operation (~O(doses × basalSegments)).  Annotate the full window
    ///      once with `PrecomputedInsulinInput.build(...)`, then slice
    ///      `annotatedDoses` to the lookback window for each call.
    ///
    ///   2. **Skip `glucoseEffects(...)`** — when `precomputedInsulin.insulinEffects`
    ///      is non-nil the function clips the pre-built effect timeline to the
    ///      needed range instead of recomputing from scratch.  This is only
    ///      valid when ISF does not change between steps (i.e. you are NOT
    ///      sweeping ISF multipliers).
    ///
    /// All other effects (carbs, RC, momentum) are computed normally.
    ///
    /// - Parameters:
    ///   - start: The starting time of the glucose prediction.
    ///   - glucoseHistory: History of glucose values: t-10h to t.
    ///   - precomputedInsulin: Pre-annotated dose data for this step.  Caller
    ///     must slice `annotatedDoses` to `[t - insulinLookback, t]` (or
    ///     `[t - lookback, t + 6h]` for future-insulin mode).
    ///   - carbEntries: History of carb entries.
    ///   - sensitivity: ISF timeline — still required for carb + RC effects.
    ///   - carbRatio: Carb ratio timeline.
    ///   - algorithmEffectsOptions: Which effects to include.
    ///   - useIntegralRetrospectiveCorrection: Use integral RC.
    ///   - includingPositiveVelocityAndRC: Include positive velocity/RC.
    ///   - useMidAbsorptionISF: Use mid-absorption ISF (ignored when
    ///     `precomputedInsulin.insulinEffects` is non-nil).
    ///   - carbAbsorptionModel: Carb absorption model.
    ///   - gradualTransitionsThreshold: RC smoothness gate (default 40 mg/dL).
    /// - Returns: A `LoopPrediction` struct.  `dosesRelativeToBasal` is
    ///   populated from `precomputedInsulin.annotatedDoses`.
    public static func generatePrediction<CarbType, GlucoseType>(
        start: Date,
        glucoseHistory: [GlucoseType],
        precomputedInsulin: PrecomputedInsulinInput,
        carbEntries: [CarbType],
        sensitivity: [AbsoluteScheduleValue<LoopQuantity>],
        carbRatio: [AbsoluteScheduleValue<Double>],
        // Correction-range timeline + scheduled basal rate — used only to clamp the
        // IntegralRC integral term (deployed-LoopKit safety bound). nil target ⇒
        // IRC clamp skipped (legacy unclamped behavior). This overload has no basal
        // schedule (insulin is precomputed), so the scheduled basal rate at the
        // prediction start must be supplied separately.
        target: GlucoseRangeTimeline? = nil,
        scheduledBasalRate: Double? = nil,
        algorithmEffectsOptions: AlgorithmEffectsOptions = .all,
        useIntegralRetrospectiveCorrection: Bool = false,
        // Asymmetric IRC gains (only used when useIntegralRetrospectiveCorrection
        // is true). Default 1.0/1.0 == standard symmetric IRC.
        ircDropGainScale: Double = 1.0,
        ircRiseGainScale: Double = 1.0,
        ircLowMemoryScale: Double = 0.0,
        ircDropDurationScale: Double = 1.0,
        ircRiseDurationScale: Double = 1.0,
        // RC integration window (how far back) / effect duration (how far forward).
        // nil => the deployed static defaults (180 min / 60 min).
        rcRetrospectionInterval: TimeInterval? = nil,
        rcEffectDuration: TimeInterval? = nil,
        // UAM projection: treat recent unexplained glucose appearance (ICE - modeled carbs)
        // as ongoing absorption, projected forward with a linear taper over this many
        // minutes. 0 = off. Continuous mechanism for unannounced meals.
        uamProjectionMinutes: Double = 0,
        // Early-ascending-limb projection (continuous complement of GBAF). Active only when
        // earlyRiseGain > 0 AND earlyRiseMinutes > 0. See earlyRiseProjectionEffects.
        earlyRiseMinutes: Double = 0,
        earlyRiseGain: Double = 0,
        earlyRiseBgLow: Double = 70,
        earlyRiseBgHigh: Double = 140,
        earlyRiseSlopeThreshold: Double = 0.3,
        includingPositiveVelocityAndRC: Bool = true,
        useLegacyRCDecay: Bool = false,
        useMidAbsorptionISF: Bool = false,
        carbAbsorptionModel: CarbAbsorptionComputable = PiecewiseLinearAbsorption(),
        adaptiveCarbAbsorption: Bool = false,
        initialAbsorptionTimeOverrun: Double = CarbMath.defaultAbsorptionTimeOverrun,
        gradualTransitionsThreshold: Double? = 40.0,
        momentumVelocityMaximum: LoopQuantity? = nil,
        momentumProjectionDuration: TimeInterval? = nil,
        // Momentum LOOKBACK: glucose history window the momentum slope is fit over.
        // nil => GlucoseMath.momentumDataInterval (15 min).
        momentumDataInterval: TimeInterval? = nil,
        useAsymmetricMomentum: Bool = false,
        useHybridAsymmetricMomentum: Bool = false,
        momentumAlphaSlow: Double = 0.15,
        momentumAlphaFast: Double = 0.85
    ) -> LoopPrediction<CarbType> where CarbType: CarbEntry, GlucoseType: GlucoseSampleValue {

        let dosesRelativeToBasal = precomputedInsulin.annotatedDoses
        let activeInsulin = dosesRelativeToBasal.insulinOnBoard(at: start)

        // ── Insulin effects ──────────────────────────────────────────────────────
        // Fast path: clip the pre-computed effect timeline to the needed range.
        // Slow path: compute from annotated doses (still faster than the full
        //            overload because annotation is already done).
        let insulinEffects: [GlucoseEffect]
        if let prebuilt = precomputedInsulin.insulinEffects {
            // Use the pre-built effects directly.  Extra entries (outside the
            // needed range) are harmless; counteractionEffects() and
            // predictGlucose() only consume entries within their required window.
            // Pass the full array — callers should pre-build with a generous
            // `effectsTo` covering the full sweep end + activity duration.
            insulinEffects = prebuilt
        } else {
            var effectsInterval = dosesRelativeToBasal.effectsInterval() ?? DateInterval(start: start, end: start)
            if let glucoseStart = glucoseHistory.first?.startDate, glucoseStart < effectsInterval.start {
                effectsInterval = effectsInterval.extendedToInclude(glucoseStart)
            }
            if let glucoseEnd = glucoseHistory.last?.endDate, glucoseEnd > effectsInterval.end {
                effectsInterval = effectsInterval.extendedToInclude(glucoseEnd)
            }
            if useMidAbsorptionISF {
                insulinEffects = dosesRelativeToBasal.glucoseEffectsMidAbsorptionISF(
                    insulinSensitivityHistory: sensitivity,
                    from: effectsInterval.start,
                    to: effectsInterval.end
                )
            } else {
                insulinEffects = dosesRelativeToBasal.glucoseEffects(
                    insulinSensitivityHistory: sensitivity,
                    from: effectsInterval.start,
                    to: effectsInterval.end
                )
            }
        }

        // ── ICE, carbs, RC, momentum — identical to the standard overload ────────
        let insulinCounteractionEffects = glucoseHistory.counteractionEffects(to: insulinEffects)

        let carbStatus = carbEntries.map(
            to: insulinCounteractionEffects,
            carbRatio: carbRatio,
            insulinSensitivity: sensitivity,
            initialAbsorptionTimeOverrun: initialAbsorptionTimeOverrun,
            absorptionModel: carbAbsorptionModel,
            adaptiveAbsorptionRateEnabled: adaptiveCarbAbsorption
        )
        let carbEffects = carbStatus.dynamicGlucoseEffects(
            from: start.addingTimeInterval(-(rcRetrospectionInterval ?? IntegralRetrospectiveCorrection.retrospectionInterval)),
            carbRatios: carbRatio,
            insulinSensitivities: sensitivity,
            absorptionModel: carbAbsorptionModel
        )
        let activeCarbs = carbStatus.dynamicCarbsOnBoard(at: start, absorptionModel: carbAbsorptionModel)

        let retrospectiveGlucoseDiscrepancies = insulinCounteractionEffects.subtracting(carbEffects)
        let retrospectiveGlucoseDiscrepanciesSummed = retrospectiveGlucoseDiscrepancies
            .combinedSums(of: LoopMath.retrospectiveCorrectionGroupingInterval * 1.01)

        let rc: RetrospectiveCorrection = useIntegralRetrospectiveCorrection
            ? IntegralRetrospectiveCorrection(effectDuration: rcEffectDuration ?? LoopMath.retrospectiveCorrectionEffectDuration, dropGainScale: ircDropGainScale, riseGainScale: ircRiseGainScale, lowMemoryScale: ircLowMemoryScale, dropDurationScale: ircDropDurationScale, riseDurationScale: ircRiseDurationScale, integrationInterval: rcRetrospectionInterval, maxEffectDuration: rcEffectDuration, useLegacyDecay: useLegacyRCDecay)
            : StandardRetrospectiveCorrection(effectDuration: rcEffectDuration ?? LoopMath.retrospectiveCorrectionEffectDuration, useLegacyDecay: useLegacyRCDecay)

        var prediction: [PredictedGlucoseValue] = []
        var retrospectiveCorrectionEffects: [GlucoseEffect] = []
        var momentumEffects: [GlucoseEffect] = []
        var totalRetrospectiveCorrectionEffect: LoopQuantity?

        if let latestGlucose = glucoseHistory.last {
            // Inputs for the IntegralRC integral-correction clamp (deployed-LoopKit
            // safety bound). nil target ⇒ clamp skipped (legacy unclamped behavior).
            let clampISF = sensitivity.closestPrior(to: start)?.value
            let clampRange = target?.closestPrior(to: start)?.value
            retrospectiveCorrectionEffects = rc.computeEffect(
                startingAt: latestGlucose,
                retrospectiveGlucoseDiscrepanciesSummed: retrospectiveGlucoseDiscrepanciesSummed,
                recencyInterval: TimeInterval(minutes: 15),
                insulinSensitivity: clampISF,
                basalRate: scheduledBasalRate,
                correctionRange: clampRange,
                retrospectiveCorrectionGroupingInterval: LoopMath.retrospectiveCorrectionGroupingInterval
            )
            totalRetrospectiveCorrectionEffect = rc.totalGlucoseCorrectionEffect

            var effects = [[GlucoseEffect]]()
            if algorithmEffectsOptions.contains(.carbs)  { effects.append(carbEffects) }
            if algorithmEffectsOptions.contains(.insulin) { effects.append(insulinEffects) }
            if uamProjectionMinutes > 0 {
                let uam = uamProjectionEffects(
                    discrepancies: retrospectiveGlucoseDiscrepancies,
                    start: start,
                    projectionDuration: .minutes(uamProjectionMinutes))
                if !uam.isEmpty { effects.append(uam) }
            }

            // Early-ascending-limb projection (continuous complement of GBAF).
            if earlyRiseGain > 0, earlyRiseMinutes > 0 {
                let er = earlyRiseProjectionEffects(
                    glucoseHistory: glucoseHistory,
                    start: start,
                    projectionDuration: .minutes(earlyRiseMinutes),
                    gain: earlyRiseGain,
                    bgLow: earlyRiseBgLow,
                    bgHigh: earlyRiseBgHigh,
                    slopeThreshold: earlyRiseSlopeThreshold)
                if !er.isEmpty { effects.append(er) }
            }

            if algorithmEffectsOptions.contains(.retrospection) {
                var useRC = true
                let rcTransitionData = glucoseHistory.filterDateRange(
                    start.addingTimeInterval(-LoopMath.retrospectiveCorrectionGroupingInterval),
                    start
                )
                if let _gtt = gradualTransitionsThreshold, !rcTransitionData.hasGradualTransitions(gradualTransitionThreshold: _gtt) {
                    useRC = false
                }
                if !includingPositiveVelocityAndRC,
                   let netRC = retrospectiveCorrectionEffects.netEffect(),
                   netRC.quantity.doubleValue(for: .milligramsPerDeciliter) > 0 {
                    useRC = false
                }
                if useRC { effects.append(retrospectiveCorrectionEffects) }
            }

            var useMomentum = true
            if algorithmEffectsOptions.contains(.momentum) {
                let momentumInputData = glucoseHistory.filterDateRange(
                    start.addingTimeInterval(-(momentumDataInterval ?? GlucoseMath.momentumDataInterval)), start
                )
                if useHybridAsymmetricMomentum {
                    momentumEffects = momentumInputData.hybridAsymmetricMomentumEffect(velocityMaximum: momentumVelocityMaximum, alphaFast: momentumAlphaFast)
                } else if useAsymmetricMomentum {
                    momentumEffects = momentumInputData.asymmetricMomentumEffect(velocityMaximum: momentumVelocityMaximum, alphaSlow: momentumAlphaSlow, alphaFast: momentumAlphaFast)
                } else {
                    momentumEffects = momentumInputData.linearMomentumEffect(
                        duration: momentumProjectionDuration ?? GlucoseMath.momentumDuration,
                        velocityMaximum: momentumVelocityMaximum,
                        gradualTransitionsThreshold: gradualTransitionsThreshold)
                }
                if !includingPositiveVelocityAndRC,
                   let netMomentum = momentumEffects.netEffect(),
                   netMomentum.quantity.doubleValue(for: .milligramsPerDeciliter) > 0 {
                    useMomentum = false
                }
            } else {
                useMomentum = false
            }

            prediction = LoopMath.predictGlucose(
                startingAt: latestGlucose,
                momentum: useMomentum ? momentumEffects : [],
                effects: effects
            )

            let finalDate = start.addingTimeInterval(InsulinMath.defaultInsulinActivityDuration)
            if let last = prediction.last, last.startDate < finalDate {
                prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
            }
        }

        return LoopPrediction(
            glucose: prediction,
            effects: LoopAlgorithmEffects(
                insulin: insulinEffects,
                carbs: carbEffects,
                carbStatus: carbStatus,
                retrospectiveCorrection: retrospectiveCorrectionEffects,
                momentum: momentumEffects,
                insulinCounteraction: insulinCounteractionEffects,
                retrospectiveGlucoseDiscrepancies: retrospectiveGlucoseDiscrepanciesSummed,
                totalRetrospectiveCorrectionEffect: totalRetrospectiveCorrectionEffect
            ),
            dosesRelativeToBasal: dosesRelativeToBasal,
            activeInsulin: activeInsulin,
            activeCarbs: activeCarbs
        )
    }

    // Helper to generate prediction with LoopPredictionInput struct
    public static func generatePrediction<CarbType, GlucoseType, InsulinDoseType>(input: LoopPredictionInput<CarbType, GlucoseType, InsulinDoseType>) -> LoopPrediction<CarbType> {

        return generatePrediction(
            start: input.glucoseHistory.last?.startDate ?? Date(),
            glucoseHistory: input.glucoseHistory,
            doses: input.doses,
            carbEntries: input.carbEntries,
            basal: input.basal,
            sensitivity: input.sensitivity,
            carbRatio: input.carbRatio,
            target: input.target,
            algorithmEffectsOptions: input.algorithmEffectsOptions,
            useIntegralRetrospectiveCorrection: input.useIntegralRetrospectiveCorrection,
            carbAbsorptionModel: input.carbAbsorptionModel.model,
            gradualTransitionsThreshold: input.gradualTransitionsThreshold
        )
    }

    // Computes an amount of insulin to correct the given prediction
    public static func insulinCorrection(
        prediction: [PredictedGlucoseValue],
        at deliveryDate: Date,
        target: GlucoseRangeTimeline,
        suspendThreshold: LoopQuantity,
        sensitivity: [AbsoluteScheduleValue<LoopQuantity>],
        insulinModel: InsulinModel
    ) -> InsulinCorrection {
        return prediction.insulinCorrection(
            to: target,
            at: deliveryDate,
            suspendThreshold: suspendThreshold,
            insulinSensitivity: sensitivity,
            model: insulinModel)
    }

    // Computes a 30 minute temp basal dose to correct the given prediction
    public static func recommendTempBasal(
        for correction: InsulinCorrection,
        neutralBasalRate: Double,
        activeInsulin: Double,
        maxBolus: Double,
        maxBasalRate: Double,
        maxActiveInsulin: Double
    ) -> TempBasalRecommendation {

        var maxBasalRate = maxBasalRate

        // TODO: Allow `highBasalThreshold` to be a configurable setting
        if case .aboveRange(min: let min, correcting: _, minTarget: let highBasalThreshold, units: _) = correction,
            min.quantity < highBasalThreshold
        {
            maxBasalRate = neutralBasalRate
        }

        // Enforce max active insulin
        let activeInsulinHeadroom = maxActiveInsulin - activeInsulin

        let maxThirtyMinuteRateToKeepActiveInsulinBelowLimit = activeInsulinHeadroom * (TimeInterval.hours(1) / tempBasalDuration) + neutralBasalRate  // 30 minutes of a U/hr rate
        maxBasalRate = Swift.min(maxThirtyMinuteRateToKeepActiveInsulinBelowLimit, maxBasalRate)

        return correction.asTempBasal(
            neutralBasalRate: neutralBasalRate,
            maxBasalRate: maxBasalRate,
            duration: tempBasalDuration
        )
    }

    // Computes a bolus or low-temp basal dose to correct the given prediction
    /// Project recent unexplained glucose appearance forward as ongoing, tapering
    /// absorption (a continuous UAM term). Rate = mean discrepancy velocity over the
    /// last `lookback`; cumulative effect c(t) = R*(t - t^2/2T) up to T, then R*T/2.
    static func uamProjectionEffects(
        discrepancies: [GlucoseEffect],          // per-5-min unexplained change (mg/dL per interval)
        start: Date,
        projectionDuration: TimeInterval,
        lookback: TimeInterval = .minutes(30),
        delta: TimeInterval = .minutes(5)
    ) -> [GlucoseEffect] {
        let unit = LoopUnit.milligramsPerDeciliter
        // Slow-on / fast-off rate estimate: trust a rise only when the LONG (30 min) mean
        // supports it, but shed it as fast as the SHORT (10 min) mean falls when
        // absorption wanes — rate = max(0, min(mean_long, mean_short)). Continuous.
        func meanRate(_ lb: TimeInterval) -> Double {
            let recent = discrepancies.filter { $0.startDate > start.addingTimeInterval(-lb) && $0.startDate <= start }
            guard !recent.isEmpty else { return 0 }
            let perInterval = recent.reduce(0.0) { $0 + $1.quantity.doubleValue(for: unit) } / Double(recent.count)
            return perInterval / (delta / 60.0)                      // mg/dL per minute
        }
        guard projectionDuration > 0 else { return [] }
        let rate = Swift.max(0, Swift.min(meanRate(lookback), meanRate(.minutes(10))))
        guard rate > 0 else { return [] }
        let T = projectionDuration / 60.0        // minutes
        let horizonMin = Swift.max(T, 360.0)
        var effects: [GlucoseEffect] = []
        var tau = 0.0
        while tau <= horizonMin {
            let c: Double = tau <= T ? rate * (tau - tau * tau / (2 * T)) : rate * T / 2
            effects.append(GlucoseEffect(startDate: start.addingTimeInterval(tau * 60),
                                         quantity: LoopQuantity(unit: unit, doubleValue: c)))
            tau += delta / 60.0
        }
        return effects
    }

    /// Early-ascending-limb forecast term — the continuous complement of GBAF.
    /// When BG sits in the low-normal band AND is rising, project the current rise forward as
    /// a tapering, meal-shaped glucose effect, so the EXISTING dosing logic starts covering an
    /// unannounced meal on its ASCENDING LIMB rather than waiting for the peak. Empirically this
    /// is the single thing oref does that Loop does not (head-to-head: oref doses the 70-100
    /// rising state where Loop suspends; equal total insulin, front-loaded onto the rise).
    ///
    /// Keyed on (low-normal level) × (positive slope):
    ///  - a smooth BG band-gate is ≈1 over [bgLow+ramp, bgHigh-ramp] and ramps linearly to 0 at
    ///    the edges, so the term is OFF at high BG (never piles onto the peak — the failure mode
    ///    of a uniform UAM/RC term, which only slides the aggressiveness curve) and OFF below
    ///    bgLow (never pushes the forecast up when already near a low);
    ///  - the slope gate is zero at/below `slopeThreshold`, so it never fires while flat or
    ///    falling (no dosing into a stall, and no dosing into a post-low rebound's reversal).
    /// Cumulative shape matches the UAM term: c(τ)=R·(τ−τ²/2T) up to T, then R·T/2 — a
    /// decelerating ramp to a bounded plateau. All forecast-side (raises predicted BG only).
    static func earlyRiseProjectionEffects<GlucoseType: GlucoseSampleValue>(
        glucoseHistory: [GlucoseType],
        start: Date,
        projectionDuration: TimeInterval,
        gain: Double,
        bgLow: Double,
        bgHigh: Double,
        bandRamp: Double = 15.0,
        slopeThreshold: Double = 0.3,
        velocityInterval: TimeInterval = .minutes(15),
        delta: TimeInterval = .minutes(5)
    ) -> [GlucoseEffect] {
        let unit = LoopUnit.milligramsPerDeciliter
        guard gain > 0, projectionDuration > 0 else { return [] }
        let win = glucoseHistory.filter { $0.startDate > start.addingTimeInterval(-velocityInterval) && $0.startDate <= start }
        guard let latest = win.last, win.count >= 2 else { return [] }
        let bgNow = latest.quantity.doubleValue(for: unit)
        // BG band gate: smooth (piecewise-linear) window, 1 inside, ramps to 0 at the edges.
        let up   = Swift.max(0, Swift.min(1, (bgNow - bgLow)  / bandRamp))
        let down = Swift.max(0, Swift.min(1, (bgHigh - bgNow) / bandRamp))
        let bandGate = up * down
        guard bandGate > 0 else { return [] }
        // Least-squares BG slope over the trailing window (mg/dL per minute).
        let t0 = win.first!.startDate
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0; let n = Double(win.count)
        for g in win {
            let x = g.startDate.timeIntervalSince(t0) / 60.0
            let y = g.quantity.doubleValue(for: unit)
            sx += x; sy += y; sxx += x * x; sxy += x * y
        }
        let denom = n * sxx - sx * sx
        guard denom != 0 else { return [] }
        let slope = (n * sxy - sx * sy) / denom
        // Projected ongoing appearance rate (mg/dL per minute) — positive only.
        let rate = gain * bandGate * Swift.max(0, slope - slopeThreshold)
        guard rate > 0 else { return [] }
        let T = projectionDuration / 60.0
        let horizonMin = Swift.max(T, 360.0)
        var effects: [GlucoseEffect] = []
        var tau = 0.0
        while tau <= horizonMin {
            let c: Double = tau <= T ? rate * (tau - tau * tau / (2 * T)) : rate * T / 2
            effects.append(GlucoseEffect(startDate: start.addingTimeInterval(tau * 60),
                                         quantity: LoopQuantity(unit: unit, doubleValue: c)))
            tau += delta / 60.0
        }
        return effects
    }

    public static func recommendAutomaticDose(
        for correction: InsulinCorrection,
        applicationFactor: Double,
        neutralBasalRate: Double,
        activeInsulin: Double,
        maxBolus: Double,
        maxBasalRate: Double,
        maxActiveInsulin: Double,
        // When non-nil, the hard "predicted-min < range-floor → zero bolus" cliff is
        // replaced by a graded ramp: the bolus is scaled by how far the predicted
        // minimum sits between this floor (e.g. the suspend threshold) and the
        // correction-range lower bound — full at/above the range floor, zero at/below
        // this floor, linear between. nil = original on/off gate.
        lowGateRampFloor: Double? = nil,
        // Predicted-min cutoff (mg/dL) below which the auto-bolus gate engages. nil = the
        // correction-range floor (original behavior). A lower value (e.g. 80) keeps the FULL
        // application factor for predicted minimums down to that level before gating — i.e.
        // "continue the application factor down to <gateThreshold>". Composes with lowGateRampFloor:
        // when both are set, the bolus ramps from rampFloor (0) up to gateThreshold (full).
        gateThreshold: Double? = nil
    ) -> AutomaticDoseRecommendation {


        let deliveryHeadroom = max(0, maxActiveInsulin - activeInsulin)

        let deliveryMax = min(maxBolus * applicationFactor, deliveryHeadroom)

        var effectiveApplicationFactor = applicationFactor
        if case .aboveRange(min: let min, correcting: _, minTarget: let minTarget, units: _) = correction {
            let unit = LoopUnit.milligramsPerDeciliter
            let minVal = min.quantity.doubleValue(for: unit)
            // The predicted-min value below which the gate engages. Defaults to the correction-range
            // floor (minTarget) — identical to the original behavior when gateThreshold is nil.
            let gateTop = gateThreshold ?? minTarget.doubleValue(for: unit)
            if minVal < gateTop {
                if let rampFloor = lowGateRampFloor {
                    let frac = gateTop > rampFloor
                        ? Swift.max(0, Swift.min(1, (minVal - rampFloor) / (gateTop - rampFloor)))
                        : 0
                    effectiveApplicationFactor *= frac
                } else {
                    effectiveApplicationFactor = 0   // hard gate below the threshold
                }
            }
        }

        let temp: TempBasalRecommendation = correction.asTempBasal(
            neutralBasalRate: neutralBasalRate,
            maxBasalRate: neutralBasalRate,
            duration: .minutes(30)
        )

        let bolusUnits = correction.asPartialBolus(
            partialApplicationFactor: effectiveApplicationFactor,
            maxBolusUnits: deliveryMax
        )

        return AutomaticDoseRecommendation(basalAdjustment: temp, direction: .from(correction: correction), bolusUnits: bolusUnits)
    }

    // Computes a manual bolus to correct the given prediction
    public static func recommendManualBolus(
        for correction: InsulinCorrection,
        maxBolus: Double,
        currentGlucose: GlucoseSampleValue,
        target: GlucoseRangeTimeline
    ) -> ManualBolusRecommendation {
        var bolus = correction.asManualBolus(maxBolus: maxBolus)

        if let targetAtCurrentGlucose = target.closestPrior(to: currentGlucose.startDate),
           currentGlucose.quantity < targetAtCurrentGlucose.value.lowerBound
        {
            bolus.notice = .currentGlucoseBelowTarget(glucose: SimpleGlucoseValue(currentGlucose))
        }

        return bolus
    }

    public static func run<LoopAlgorithmInputType: AlgorithmInput>(input: LoopAlgorithmInputType) -> AlgorithmOutput<LoopAlgorithmInputType.CarbType> {

        var prediction = LoopPrediction(
            glucose: [],
            effects: LoopAlgorithmEffects(
                insulin: [],
                carbs: [],
                carbStatus: [CarbStatus<LoopAlgorithmInputType.CarbType>](),
                retrospectiveCorrection: [],
                momentum: [],
                insulinCounteraction: [],
                retrospectiveGlucoseDiscrepancies: []
            ),
            dosesRelativeToBasal: []
        )

        // Now validate/recommend
        let result: Result<LoopAlgorithmDoseRecommendation,Error>

        do {
            guard let latestGlucose = input.glucoseHistory.last else {
                throw AlgorithmError.missingGlucose
            }

            guard input.predictionStart.timeIntervalSince(latestGlucose.startDate) < inputDataRecencyInterval else {
                throw AlgorithmError.glucoseTooOld
            }

            // When running the algorithm for automated dosing, future basal should not be included
            if let basalEnd = input.doses.filter({ $0.deliveryType == .basal }).map({ $0.endDate }).max() {
                guard !input.recommendationType.automated || basalEnd <= input.predictionStart else {
                    throw AlgorithmError.futureBasalNotAllowed
                }
            }

            let forecastEnd = input.predictionStart.addingTimeInterval(input.recommendationInsulinModel.effectDuration).dateCeiledToTimeInterval(GlucoseMath.defaultDelta)

            let glucoseStart = input.glucoseHistory.first?.startDate ?? input.predictionStart

            // Make sure ISF covers needed timeline
            let recommendationEffectInterval = DateInterval(
                start: input.predictionStart,
                duration: input.recommendationInsulinModel.effectDuration)
            let neededISFInterval = timelineIntervalForSensitivity(
                doses: input.doses,
                glucoseHistoryStart: glucoseStart,
                recommendationEffectInterval: recommendationEffectInterval
            )
            guard let sensitivityStartDate = input.sensitivity.first?.startDate, sensitivityStartDate <= neededISFInterval.start else {
                throw AlgorithmError.sensitivityTimelineStartsTooLate
            }
            guard let sensitivityEndDate = input.sensitivity.last?.endDate, sensitivityEndDate >= neededISFInterval.end else {
                throw AlgorithmError.sensitivityTimelineEndsTooEarly
            }

            // Make sure Basal covers needed timeline
            guard let scheduledBasalRate = input.basal.closestPrior(to: input.predictionStart)?.value else {
                throw AlgorithmError.basalTimelineIncomplete
            }

            guard let suspendThreshold = input.suspendThreshold ?? input.target.closestPrior(to: input.predictionStart)?.value.lowerBound else {
                throw AlgorithmError.missingSuspendThreshold
            }

            prediction = generatePrediction(
                start: input.predictionStart,
                glucoseHistory: input.glucoseHistory,
                doses: input.doses,
                carbEntries: input.carbEntries,
                basal: input.basal,
                sensitivity: input.sensitivity,
                carbRatio: input.carbRatio,
                algorithmEffectsOptions: .all,
                useIntegralRetrospectiveCorrection: input.useIntegralRetrospectiveCorrection,
                includingPositiveVelocityAndRC: input.includePositiveVelocityAndRC,
                useMidAbsorptionISF: input.useMidAbsorptionISF,
                carbAbsorptionModel: input.carbAbsorptionModel.model,
                gradualTransitionsThreshold: input.gradualTransitionsThreshold
            )

            let sensitivityForDosing: [AbsoluteScheduleValue<LoopQuantity>]
            if input.useMidAbsorptionISF {
                sensitivityForDosing = input.sensitivity
            } else {
                // This sets a single ISF value for the duration of the dose.
                let sensitivityEnd = max(forecastEnd, prediction.effects.insulin.last?.startDate ?? .distantPast)
                let sensitivityAtPredictionStart = input.sensitivity.first { $0.startDate <= input.predictionStart && $0.endDate >= input.predictionStart }!
                let sensitivityOverPrediction = AbsoluteScheduleValue(
                    startDate: sensitivityAtPredictionStart.startDate,
                    endDate: sensitivityEnd,
                    value: sensitivityAtPredictionStart.value
                )
                sensitivityForDosing = [sensitivityOverPrediction]
            }

            let correction = insulinCorrection(
                prediction: prediction.glucose,
                at: input.predictionStart,
                target: input.target,
                suspendThreshold: suspendThreshold,
                sensitivity: sensitivityForDosing,
                insulinModel: input.recommendationInsulinModel)

            let maxActiveInsulin = input.maxBolus * (input.maxActiveInsulinMultiplier ?? 2)

            switch input.recommendationType {
            case .manualBolus:
                let recommendation = recommendManualBolus(
                    for: correction,
                    maxBolus: input.maxBolus,
                    currentGlucose: latestGlucose,
                    target: input.target)
                result = .success(.init(manual: recommendation))
            case .automaticBolus:
                let recommendation = recommendAutomaticDose(
                    for: correction,
                    applicationFactor: input.automaticBolusApplicationFactor ?? defaultBolusPartialApplicationFactor,
                    neutralBasalRate: scheduledBasalRate,
                    activeInsulin: prediction.activeInsulin!,
                    maxBolus: input.maxBolus,
                    maxBasalRate: input.maxBasalRate,
                    maxActiveInsulin: maxActiveInsulin)
                result = .success(.init(automatic: recommendation))
            case .tempBasal:
                let recommendation = recommendTempBasal(
                    for: correction,
                    neutralBasalRate: scheduledBasalRate,
                    activeInsulin: prediction.activeInsulin!,
                    maxBolus: input.maxBolus,
                    maxBasalRate: input.maxBasalRate,
                    maxActiveInsulin: maxActiveInsulin)
                result = .success(.init(automatic: AutomaticDoseRecommendation(basalAdjustment: recommendation, direction: .from(correction: correction))))
            }
        } catch {
            result = .failure(error)
        }

        return AlgorithmOutput(
            recommendationResult: result,
            predictedGlucose: prediction.glucose,
            effects: prediction.effects,
            dosesRelativeToBasal: prediction.dosesRelativeToBasal,
            activeInsulin: prediction.activeInsulin,
            activeCarbs: prediction.activeCarbs
        )
    }
}
