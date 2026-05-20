//
//  InsulinMath.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 1/30/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation


public struct InsulinMath {
    public static let defaultInsulinActivityDuration: TimeInterval = TimeInterval(hours: 6) + TimeInterval(minutes: 10)
    public static let longestInsulinActivityDuration: TimeInterval = TimeInterval(hours: 6) + TimeInterval(minutes: 10)
}

/// How a dose's glucose effect is decomposed into an active-insulin term
/// (scaled by `activeSensitivity`, lowers BG) and an EGP-credit term (scaled
/// by `scheduleBaselineSensitivity`, raises BG). Both decompositions split
/// `netBasalUnits` into `(active − egpRaise) = netBasalUnits`, so when the two
/// sensitivities are equal BOTH reduce to the classic `netBasalUnits × -ISF`.
public enum SensitivityDecomposition: Sendable {
    /// Phase 1: split by SIGN of `netBasalUnits`.
    ///   active   = max(0, nbu)   (delivered above schedule)
    ///   egpRaise = max(0, -nbu)  (shortfall below schedule)
    /// One term is always zero. A sub-basal delivery has active = 0, so
    /// boosting `activeSensitivity` cannot amplify it.
    case netBasalUnits
    /// Phase 2: split by PHYSICAL delivery vs scheduled-basal offset.
    ///   active   = volume                 (all physically delivered insulin)
    ///   egpRaise = volume - nbu           (the scheduled-basal EGP offset)
    /// Both terms are ≥ 0. A sub-basal delivery still has active = volume, so
    /// boosting `activeSensitivity` amplifies the real insulin on board — the
    /// physically-correct behavior for a sensitivity override.
    case physicalDelivery
}

extension BasalRelativeDose {
    private func continuousDeliveryInsulinOnBoard(at date: Date, delta: TimeInterval) -> Double {
        let doseDuration = endDate.timeIntervalSince(startDate)  // t1
        let time = date.timeIntervalSince(startDate)
        var iob: Double = 0
        var doseDate = TimeInterval(0)  // i

        repeat {
            let segment: Double

            if doseDuration > 0 {
                segment = max(0, min(doseDate + delta, doseDuration) - doseDate) / doseDuration
            } else {
                segment = 1
            }

            iob += segment * insulinModel.percentEffectRemaining(at: time - doseDate)
            doseDate += delta
        } while doseDate <= min(floor((time + insulinModel.delay) / delta) * delta, doseDuration)

        return iob
    }

    func insulinOnBoard(at date: Date, delta: TimeInterval) -> Double {
        let time = date.timeIntervalSince(startDate)
        guard time >= 0 else {
            return 0
        }

        // Consider doses within the delta time window as momentary
        if endDate.timeIntervalSince(startDate) <= 1.05 * delta {
            return netBasalUnits * insulinModel.percentEffectRemaining(at: time)
        } else {
            return netBasalUnits * continuousDeliveryInsulinOnBoard(at: date, delta: delta)
        }
    }

    private func continuousDeliveryPercentEffect(at date: Date, delta: TimeInterval) -> Double {
        let doseDuration = endDate.timeIntervalSince(startDate)  // t1
        let time = date.timeIntervalSince(startDate)
        var value: Double = 0
        var doseDate = TimeInterval(0)  // i

        repeat {
            let segment: Double

            if doseDuration > 0 {
                segment = max(0, min(doseDate + delta, doseDuration) - doseDate) / doseDuration
            } else {
                segment = 1
            }

            value += segment * (1.0 - insulinModel.percentEffectRemaining(at: time - doseDate))
            doseDate += delta
        } while doseDate <= min(floor((time + insulinModel.delay) / delta) * delta, doseDuration)

        return value
    }

    func glucoseEffect(at date: Date, insulinSensitivity: Double, delta: TimeInterval) -> Double {
        return glucoseEffect(at: date,
                             activeSensitivity: insulinSensitivity,
                             scheduleBaselineSensitivity: insulinSensitivity,
                             delta: delta)
    }

    /// Decomposed glucose-effect: splits this dose's contribution into the
    /// **active-insulin** piece (positive `netBasalUnits` — delivered insulin
    /// lowering BG, scaled by `activeSensitivity`) and the **EGP-credit**
    /// piece (negative `netBasalUnits` — shortfall vs scheduled basal, treated
    /// as positive BG-effect, scaled by `scheduleBaselineSensitivity`).
    ///
    /// At `activeSensitivity == scheduleBaselineSensitivity` (the default in
    /// the single-argument overload), output is bit-identical to the original
    /// `netBasalUnits × -ISF × pd` formula.
    ///
    /// Passing different values lets sensitivity overrides (exercise, sick-
    /// day) scale only the term they physically affect. An exercise preset
    /// that means "insulin works 2× harder right now" should boost
    /// `activeSensitivity` but leave `scheduleBaselineSensitivity` at
    /// scheduled — otherwise the EGP-credit assumption-from-suspending also
    /// gets 2×, which is the opposite of what the model physically represents.
    /// Splits `netBasalUnits` into (activeUnits, egpRaiseUnits) per the chosen
    /// decomposition. Invariant: `activeUnits - egpRaiseUnits == netBasalUnits`.
    /// effect = activeUnits × -activeSensitivity × pd + egpRaiseUnits × +egpSensitivity × pd.
    func decomposedUnits(_ decomposition: SensitivityDecomposition) -> (active: Double, egpRaise: Double) {
        let nbu = netBasalUnits
        switch decomposition {
        case .netBasalUnits:
            return (Swift.max(0, nbu), Swift.max(0, -nbu))
        case .physicalDelivery:
            return (volume, volume - nbu)
        }
    }

    func glucoseEffect(at date: Date,
                       activeSensitivity: Double,
                       scheduleBaselineSensitivity: Double,
                       delta: TimeInterval,
                       decomposition: SensitivityDecomposition = .netBasalUnits) -> Double {
        let time = date.timeIntervalSince(startDate)

        guard time >= 0 else {
            return 0
        }

        let pd: Double
        if endDate.timeIntervalSince(startDate) <= 1.05 * delta {
            pd = 1.0 - insulinModel.percentEffectRemaining(at: time)
        } else {
            pd = continuousDeliveryPercentEffect(at: date, delta: delta)
        }
        let (active, egpRaise) = decomposedUnits(decomposition)
        return active * -activeSensitivity * pd + egpRaise * scheduleBaselineSensitivity * pd
    }

    func glucoseEffect(during interval: DateInterval, insulinSensitivity: Double, delta: TimeInterval) -> Double {
        return glucoseEffect(during: interval,
                             activeSensitivity: insulinSensitivity,
                             scheduleBaselineSensitivity: insulinSensitivity,
                             delta: delta)
    }

    /// Interval-form decomposed glucose-effect. Same split convention as the
    /// point-form `glucoseEffect(at:activeSensitivity:scheduleBaselineSensitivity:delta:)`.
    func glucoseEffect(during interval: DateInterval,
                       activeSensitivity: Double,
                       scheduleBaselineSensitivity: Double,
                       delta: TimeInterval,
                       decomposition: SensitivityDecomposition = .netBasalUnits) -> Double {
        let start = interval.start.timeIntervalSince(startDate)
        let end = interval.end.timeIntervalSince(startDate)

        guard end-start >= 0 else {
            return 0
        }

        let effect: Double
        if endDate.timeIntervalSince(startDate) <= 1.05 * delta {
            effect = insulinModel.percentEffectRemaining(at: start) - insulinModel.percentEffectRemaining(at: end)
        } else {
            let startPercentRemaining = 1 - continuousDeliveryPercentEffect(at: interval.start, delta: delta)
            let endPercentRemaining = 1 - continuousDeliveryPercentEffect(at: interval.end, delta: delta)
            effect = startPercentRemaining - endPercentRemaining
        }
        let (active, egpRaise) = decomposedUnits(decomposition)
        return active * -activeSensitivity * effect + egpRaise * scheduleBaselineSensitivity * effect
    }
}


extension InsulinDose {

    /// Annotates a dose with the context of a history of scheduled basal rates
    ///
    /// If the dose crosses a schedule boundary, it will be split into multiple doses so each dose has a
    /// single scheduled basal rate.
    ///
    /// - Parameter basalHistory: The history of basal schedule values to apply. Only schedule values overlapping the dose should be included.
    /// - Returns: An array of annotated doses
    func annotated(with basalHistory: [AbsoluteScheduleValue<Double>]) -> [BasalRelativeDose] {

        guard deliveryType == .basal else {
            preconditionFailure("basalDeliveryTotal called on dose that is not a temp basal!")
        }

        var doses: [BasalRelativeDose] = []

        for (index, basalItem) in basalHistory.enumerated() {
            let startDate: Date
            let endDate: Date

            if index == 0 {
                startDate = self.startDate
            } else {
                startDate = basalItem.startDate
            }

            if index == basalHistory.count - 1 {
                endDate = self.endDate
            } else {
                endDate = basalHistory[index + 1].startDate
            }

            let segmentStartDate = max(startDate, self.startDate)
            let segmentEndDate = max(startDate, min(endDate, self.endDate))
            let segmentDuration = segmentEndDate.timeIntervalSince(segmentStartDate)

            let segmentVolume: Double
            if duration > 0 {
                segmentVolume = volume * (segmentDuration / duration)
            } else {
                segmentVolume = 0
            }

            let annotatedDose = BasalRelativeDose(
                type: .basal(scheduledRate: basalItem.value),
                startDate: segmentStartDate,
                endDate: segmentEndDate,
                volume: segmentVolume,
                insulinModel: insulinModel
            )

            doses.append(annotatedDose)
        }

        return doses
    }
}

public extension Array where Element == AbsoluteScheduleValue<Double> {
    func trimmed(from start: Date? = nil, to end: Date? = nil) -> [AbsoluteScheduleValue<Double>] {
        return self.compactMap { (entry) -> AbsoluteScheduleValue<Double>? in
            if let start, entry.endDate < start {
                return nil
            }
            if let end, entry.startDate > end {
                return nil
            }
            return AbsoluteScheduleValue(
                startDate: Swift.max(start ?? entry.startDate, entry.startDate),
                endDate: Swift.min(end ??  entry.endDate, entry.endDate),
                value: entry.value
            )
        }
    }
}


extension Collection where Element: InsulinDose {

    /// Returns an array of BasalRelativeDoses, based on annotating a sequence of dose entries with the given basal history.
    ///
    /// Doses which cross time boundaries in the basal rate schedule are split into multiple entries.
    ///
    /// - Parameter basalSchedule: A history of basal rates covering the timespan of these doses.
    /// - Parameter fillBasalGaps: If true, the returned array will interpolate doses from basal schedule for those parts of the 
    ///                             timeline that this array does not cover.
    /// - Returns: An array of annotated dose entries
    public func annotated(with basalHistory: [AbsoluteScheduleValue<Double>], fillBasalGaps: Bool = false) -> [BasalRelativeDose] {
        var annotatedDoses: [BasalRelativeDose] = []

        let basalAdjustments = self.filter { $0.deliveryType == .basal }

        let date = [basalHistory.first?.startDate, basalAdjustments.first?.startDate].compactMap { $0 }.min()

        if !fillBasalGaps {
            guard self.count > 0 else {
                return []
            }
        }

        guard var date else {
            return []
        }

        func fillGapWithBasal(start: Date, end: Date) -> [BasalRelativeDose] {
            let basals = basalHistory.trimmed(from: start, to: end)
            return basals.map { entry in
                BasalRelativeDose(
                    type: .basal(scheduledRate: entry.value),
                    startDate: entry.startDate,
                    endDate: entry.endDate,
                    volume: entry.value * entry.duration.hours
                )
            }
        }

        for dose in self {
            if dose.deliveryType != .basal {
                annotatedDoses.append(BasalRelativeDose.fromBolus(dose: dose))
                continue
            }

            if date < dose.startDate && fillBasalGaps {
                // Fill date <-> dose.startDate gap with basal
                annotatedDoses.append(contentsOf: fillGapWithBasal(start: date, end: dose.startDate))
            }

            let basalItems = basalHistory.filterDateRange(dose.startDate, dose.endDate)
            annotatedDoses += dose.annotated(with: basalItems)
            date = dose.endDate
        }

        let endDate = [basalHistory.last?.endDate, basalAdjustments.last?.endDate].compactMap { $0 }.max() ?? date

        if date < endDate && fillBasalGaps {
            annotatedDoses.append(contentsOf: fillGapWithBasal(start: date, end: endDate))
        }

        return annotatedDoses
    }

    /// Annotates a sequence of dose entries with the configured basal history
    ///
    /// Doses which cross time boundaries in the basal rate schedule are split into multiple entries.
    ///
    /// - Parameter basalSchedule: A history of basal rates covering the timespan of these doses.
    /// - Returns: An array of annotated dose entries
    public func annotated(with basalHistory: [AbsoluteScheduleValue<Double>]) -> [BasalRelativeDose] {
        var annotatedDoses: [BasalRelativeDose] = []

        for dose in self {
            if dose.deliveryType == .basal {
                let basalItems = basalHistory.filterDateRange(dose.startDate, dose.endDate)
                annotatedDoses += dose.annotated(with: basalItems)
            } else {
                annotatedDoses.append(BasalRelativeDose.fromBolus(dose: dose))
            }
        }

        return annotatedDoses
    }

}

extension Collection where Element == BasalRelativeDose {

    /**
     Calculates the timeline of insulin remaining for a collection of doses

     - parameter longestEffectDuration: The longest duration that a dose could be active.
     - parameter start:                 The date to start the timeline
     - parameter end:                   The date to end the timeline
     - parameter delta:                 The differential between timeline entries, Defaults to 5 minutes.

     - returns: A sequence of insulin amount remaining
     */
    public func insulinOnBoardTimeline(
        longestEffectDuration: TimeInterval = InsulinMath.defaultInsulinActivityDuration,
        from start: Date? = nil,
        to end: Date? = nil,
        delta: TimeInterval = GlucoseMath.defaultDelta
    ) -> [InsulinValue] {
        guard let (start, end) = LoopMath.simulationDateRangeForSamples(self, from: start, to: end, duration: longestEffectDuration, delta: delta) else {
            return []
        }

        var date = start
        var values = [InsulinValue]()

        repeat {
            let value = reduce(0) { (value, dose) -> Double in
                return value + dose.insulinOnBoard(at: date, delta: delta)
            }

            values.append(InsulinValue(startDate: date, value: value))
            date = date.addingTimeInterval(delta)
        } while date <= end

        return values
    }

    /**
     Calculates insulin remaining at a given point in time for a collection of doses

     - parameter date:                  The date at which to calculate remaining insulin.  If nil, current date is used.

     - returns: Insulin amount remaining at specified time
     */
    public func insulinOnBoard(
        at date: Date
    ) -> Double {
        return reduce(0) { (value, dose) -> Double in
            return value + dose.insulinOnBoard(at: date, delta: GlucoseMath.defaultDelta)
        }
    }


    /// Calculates the timeline of glucose effects for a collection of doses. The ISF used for a given dose is based on the ISF in effect at the dose start time.
    ///
    /// - Parameters:
    ///   - insulinSensitivityHistory: The timeline of glucose effect per unit of insulin
    ///   - start: The earliest date of effects to return
    ///   - end: The latest date of effects to return. If nil is passed, it will be calculated from the last sample end date plus the longestEffectDuration.
    ///   - delta: The interval between returned effects
    /// - Returns: An array of glucose effects for the duration of the doses
    public func glucoseEffects(
        insulinSensitivityHistory: [AbsoluteScheduleValue<LoopQuantity>],
        from start: Date? = nil,
        to end: Date? = nil,
        delta: TimeInterval = TimeInterval(/* minutes: */60 * 5)
    ) -> [GlucoseEffect] {
        return glucoseEffects(insulinSensitivityHistory: insulinSensitivityHistory,
                              scheduleBaselineSensitivityHistory: nil,
                              from: start, to: end, delta: delta)
    }

    /// Decomposed timeline of glucose effects. The `insulinSensitivityHistory`
    /// schedule scales the **active-insulin** term (positive `netBasalUnits`),
    /// while `scheduleBaselineSensitivityHistory` (when non-nil) scales the
    /// **EGP-credit** term (negative `netBasalUnits`). With nil, output is
    /// bit-identical to the single-schedule overload.
    public func glucoseEffects(
        insulinSensitivityHistory: [AbsoluteScheduleValue<LoopQuantity>],
        scheduleBaselineSensitivityHistory: [AbsoluteScheduleValue<LoopQuantity>]?,
        from start: Date? = nil,
        to end: Date? = nil,
        delta: TimeInterval = TimeInterval(/* minutes: */60 * 5),
        decomposition: SensitivityDecomposition = .netBasalUnits
    ) -> [GlucoseEffect] {

        // In physical-delivery mode a net-zero basal still carries physical
        // insulin (active = volume) that an activeSensitivity boost makes more
        // potent than the EGP offset, so it cannot be filtered on net units.
        let activeEntries = self.filter({ entry in
            decomposition == .physicalDelivery ? entry.volume != 0 : entry.netBasalUnits != 0
        })

        let longestDIA = InsulinMath.longestInsulinActivityDuration
        guard let (start, end) = LoopMath.simulationDateRangeForSamples(activeEntries, from: start, to: end, duration: longestDIA, delta: delta) else {
            return []
        }

        let unit = LoopUnit.milligramsPerDeciliter

        // Sort doses by startDate, pre-compute each dose's ISFs (depend only
        // on startDate, not on the evaluation date) and its asymptotic effect
        // (the value `dose.glucoseEffect(at:)` returns once the dose is fully
        // past its DIA — non-zero, since cumulative effect saturates rather
        // than decays back to 0).
        let sortedActive = activeEntries.sorted { $0.startDate < $1.startDate }
        // Tuple form: (dose, activeISF, baselineISF, decayDate, asymptote).
        // Nested structs aren't permitted inside a generic function in Swift.
        let entries: [(dose: Element, activeISF: Double, baselineISF: Double, decayDate: Date, asymptote: Double)] = sortedActive.map { dose in
            guard let isfScheduleValue = insulinSensitivityHistory.closestPrior(to: dose.startDate),
                  isfScheduleValue.endDate >= dose.startDate else {
                preconditionFailure("ISF History must cover dose startDates")
            }
            let activeISF = isfScheduleValue.value.doubleValue(for: unit)
            let baselineISF: Double
            if let baseHistory = scheduleBaselineSensitivityHistory,
               let baseEntry = baseHistory.closestPrior(to: dose.startDate),
               baseEntry.endDate >= dose.startDate {
                baselineISF = baseEntry.value.doubleValue(for: unit)
            } else {
                baselineISF = activeISF
            }
            let decayDate = dose.endDate.addingTimeInterval(longestDIA)
            // Asymptotic value: decomposed glucoseEffect evaluated past full decay.
            let asymptote = dose.glucoseEffect(
                at: decayDate.addingTimeInterval(delta),
                activeSensitivity: activeISF,
                scheduleBaselineSensitivity: baselineISF,
                delta: delta,
                decomposition: decomposition
            )
            return (dose, activeISF, baselineISF, decayDate, asymptote)
        }

        var timePoints: [Date] = []
        do {
            var d = start
            while d <= end { timePoints.append(d); d = d.addingTimeInterval(delta) }
        }
        let nPoints = timePoints.count
        var values: [GlucoseEffect] = []
        values.reserveCapacity(nPoints)

        // Sliding window:
        //   lastStarted: count of doses whose startDate <= date.
        //   activeIndices: indices in [..lastStarted) that are NOT yet fully
        //     decayed (decayDate >= date). Once a dose decays, its asymptote
        //     is added to `accumulatedDecayed` and it is removed from the set.
        //   accumulatedDecayed: sum of asymptotes for all decayed doses (a
        //     constant baseline added to every subsequent timestep, because the
        //     cumulative-effect timeline retains decayed contributions forever).
        var lastStarted = 0
        var activeIndices: [Int] = []
        var accumulatedDecayed = 0.0

        let progressEvery = Swift.max(500, nPoints / 50)
        let progressEnabled = (ProcessInfo.processInfo.environment["GLUCOSE_EFFECTS_PROGRESS"] != nil)
        let progressStart = Date()

        for (ti, date) in timePoints.enumerated() {
            while lastStarted < entries.count && entries[lastStarted].dose.startDate <= date {
                activeIndices.append(lastStarted)
                lastStarted += 1
            }
            // Drop decayed entries; absorb their asymptote into the constant.
            var writeIdx = 0
            for readIdx in 0..<activeIndices.count {
                let i = activeIndices[readIdx]
                if entries[i].decayDate < date {
                    accumulatedDecayed += entries[i].asymptote
                } else {
                    activeIndices[writeIdx] = i
                    writeIdx += 1
                }
            }
            if writeIdx < activeIndices.count {
                activeIndices.removeLast(activeIndices.count - writeIdx)
            }

            var value = accumulatedDecayed
            for i in activeIndices {
                let e = entries[i]
                value += e.dose.glucoseEffect(at: date,
                                              activeSensitivity: e.activeISF,
                                              scheduleBaselineSensitivity: e.baselineISF,
                                              delta: delta,
                                              decomposition: decomposition)
            }
            values.append(GlucoseEffect(startDate: date,
                                        quantity: LoopQuantity(unit: unit, doubleValue: value)))

            if progressEnabled && (ti % progressEvery == 0) && ti > 0 {
                let elapsed = Date().timeIntervalSince(progressStart)
                let frac = Double(ti) / Double(nPoints)
                let eta = elapsed / Swift.max(frac, 1e-6) - elapsed
                let msg = String(format: "  glucoseEffects: %3.0f%% (%d/%d, %.1fs elapsed, ~%.1fs remaining, active=%d)\n",
                                 frac*100, ti, nPoints, elapsed, eta, activeIndices.count)
                if let d = msg.data(using: String.Encoding.utf8) {
                    FileHandle.standardError.write(d)
                }
            }
        }

        return values
    }


    /// Calculates the timeline of glucose effects for a collection of doses.  Effects for a specific dose will vary over the course
    /// of that dose's absoption interval based on the timeline of insulin sensitivity.
    ///
    /// - Parameters:
    ///   - longestEffectDuration: The longest duration that a dose could be active.
    ///   - insulinSensitivityHistory: A timeline of glucose effect per unit of insulin
    ///   - start: The earliest date of effects to return
    ///   - end: The latest date of effects to return
    ///   - delta: The interval between returned effects
    /// - Returns: An array of glucose effects for the duration of the doses
    public func glucoseEffectsMidAbsorptionISF(
        longestEffectDuration: TimeInterval = InsulinMath.defaultInsulinActivityDuration,
        insulinSensitivityHistory: [AbsoluteScheduleValue<LoopQuantity>],
        from start: Date? = nil,
        to end: Date? = nil,
        delta: TimeInterval = TimeInterval(/* minutes: */60 * 5)
    ) -> [GlucoseEffect] {
        return glucoseEffectsMidAbsorptionISF(
            longestEffectDuration: longestEffectDuration,
            insulinSensitivityHistory: insulinSensitivityHistory,
            scheduleBaselineSensitivityHistory: nil,
            from: start, to: end, delta: delta
        )
    }

    /// Decomposed mid-absorption variant. The `insulinSensitivityHistory`
    /// schedule scales the active-insulin term (positive `netBasalUnits`);
    /// `scheduleBaselineSensitivityHistory` (when non-nil) scales the EGP-
    /// credit term (negative `netBasalUnits`). With nil, output is bit-
    /// identical to the single-schedule overload. The baseline ISF is looked
    /// up at the start of each active-schedule segment; if the baseline
    /// schedule changes within an active segment, the segment-start value
    /// applies — fine for the typical case (baseline is the unmodulated
    /// hourly schedule, active is the same plus fine-grained per-step
    /// boosts).
    public func glucoseEffectsMidAbsorptionISF(
        longestEffectDuration: TimeInterval = InsulinMath.defaultInsulinActivityDuration,
        insulinSensitivityHistory: [AbsoluteScheduleValue<LoopQuantity>],
        scheduleBaselineSensitivityHistory: [AbsoluteScheduleValue<LoopQuantity>]?,
        from start: Date? = nil,
        to end: Date? = nil,
        delta: TimeInterval = TimeInterval(/* minutes: */60 * 5),
        decomposition: SensitivityDecomposition = .netBasalUnits
    ) -> [GlucoseEffect] {
        guard let (start, end) = LoopMath.simulationDateRangeForSamples(self.filter({ entry in
            decomposition == .physicalDelivery ? entry.volume != 0 : entry.netBasalUnits != 0
        }), from: start, to: end, duration: longestEffectDuration, delta: delta) else {
            return []
        }

        let unit = LoopUnit.milligramsPerDeciliter
        let dosesArray = Array(self)
        let egpHistory = scheduleBaselineSensitivityHistory

        // Build the list of time points up front. timePoints[i] is the date at
        // which the cumulative effect through that time is recorded.
        // increments[i] = effect contribution during (timePoints[i-1], timePoints[i]];
        // increments[0] = 0 (base case — no doses applied yet at start).
        var timePoints: [Date] = []
        do {
            var d = start
            while d <= end {
                timePoints.append(d)
                d = d.addingTimeInterval(delta)
            }
        }
        let n = timePoints.count
        guard n > 1 else {
            return timePoints.map { GlucoseEffect(startDate: $0, quantity: LoopQuantity(unit: unit, doubleValue: 0)) }
        }

        // Parallelize the per-step increments across CPU cores. Each step's
        // increment depends only on its own (lastDate, date) interval — there's
        // no cross-step dependency until the final cumsum.
        var increments = [Double](repeating: 0, count: n)

        // Reduce loop body to a closure-free static-like body to keep
        // capture/Sendable surface minimal. concurrentPerform's closure isn't
        // @Sendable, so this is tolerated by the compiler.
        increments.withUnsafeMutableBufferPointer { incBuf in
            DispatchQueue.concurrentPerform(iterations: n - 1) { idx in
                // idx in 0..<n-1 maps to step (idx+1)
                let i = idx + 1
                let lastDate = timePoints[i - 1]
                let date = timePoints[i]
                var inc = 0.0
                let isfSegments = insulinSensitivityHistory.filterDateRange(lastDate, date)
                if isfSegments.isEmpty {
                    // Outside ISF coverage; treat increment as 0
                    incBuf[i] = 0
                    return
                }
                for dose in dosesArray {
                    for segment in isfSegments {
                        let segStart = Swift.max(lastDate, segment.startDate)
                        let segEnd   = Swift.min(date,    segment.endDate)
                        if segStart != segEnd {
                            let activeISF = segment.value.doubleValue(for: unit)
                            let baselineISF: Double
                            if let egp = egpHistory,
                               let baseEntry = egp.closestPrior(to: segStart),
                               baseEntry.endDate >= segStart {
                                baselineISF = baseEntry.value.doubleValue(for: unit)
                            } else {
                                baselineISF = activeISF
                            }
                            inc += dose.glucoseEffect(
                                during: DateInterval(start: segStart, end: segEnd),
                                activeSensitivity: activeISF,
                                scheduleBaselineSensitivity: baselineISF,
                                delta: delta,
                                decomposition: decomposition
                            )
                        }
                    }
                }
                incBuf[i] = inc
            }
        }

        // Cumsum + emit GlucoseEffect — fast, single-threaded.
        var values = [GlucoseEffect]()
        values.reserveCapacity(n)
        var running = 0.0
        for i in 0..<n {
            running += increments[i]
            values.append(GlucoseEffect(startDate: timePoints[i],
                                        quantity: LoopQuantity(unit: unit, doubleValue: running)))
        }
        return values
    }

    /// Calculates the timeline of glucose effects for a collection of doses at specified points in time. Effects for a specific dose will vary over the course
    /// of that dose's absoption interval based on the timeline of insulin sensitivity.
    ///
    /// - Parameters:
    ///   - longestEffectDuration: The longest duration that a dose could be active.
    ///   - insulinSensitivityTimeline: A timeline of glucose effect per unit of insulin
    ///   - effectDates: The dates at which to calculate glucose effects
    ///   - delta: The interval below which to consider doses as momentary
    /// - Returns: An array of glucose effects for the duration of the doses
    public func glucoseEffects(
        longestEffectDuration: TimeInterval = InsulinMath.defaultInsulinActivityDuration,
        insulinSensitivityTimeline: [AbsoluteScheduleValue<LoopQuantity>],
        effectDates: [Date],
        delta: TimeInterval = TimeInterval(/* minutes: */60 * 5)
    ) -> [GlucoseEffect] {

        var lastDate = effectDates.first!
        var values = [GlucoseEffect]()
        let unit = LoopUnit.milligramsPerDeciliter

        for date in effectDates {
            // Sum effects over doses
            let value = reduce(0) { (value, dose) -> Double in
                guard date != lastDate else {
                    return 0
                }

                // Sum effects over pertinent ISF timeline segments
                let isfSegments = insulinSensitivityTimeline.filterDateRange(lastDate, date)
                return value + isfSegments.reduce(0, { partialResult, segment in
                    let start = Swift.max(lastDate, segment.startDate)
                    let end = Swift.min(date, segment.endDate)
                    let effect = dose.glucoseEffect(during: DateInterval(start: start, end: end), insulinSensitivity: segment.value.doubleValue(for: unit), delta: delta)
                    return partialResult + effect
                })
            }

            values.append(GlucoseEffect(startDate: date, quantity: LoopQuantity(unit: unit, doubleValue: value)))
            lastDate = date
        }

        return values
    }
}
