import Foundation

/// A CGM reading.
public struct AdaptiveGlucoseSample: Sendable, Equatable, Codable {
    public var date: Date
    /// mg/dL
    public var value: Double
    public init(date: Date, value: Double) { self.date = date; self.value = value }
}

/// Insulin that was delivered (or is being delivered). Boluses have `end == start`; a basal or temp segment carries
/// the units it delivers over `start..<end` (spread evenly in 5-minute pieces by the insulin model).
public struct AdaptiveDose: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case bolus, basal }
    public var start: Date
    public var end: Date
    public var units: Double
    public var kind: Kind
    /// Given by the algorithm (automatic bolus, temp basal) rather than the user.
    public var automatic: Bool
    public init(start: Date, end: Date, units: Double, kind: Kind, automatic: Bool) {
        self.start = start; self.end = end; self.units = units; self.kind = kind; self.automatic = automatic
    }
}

/// An entered carb amount, absorbed linearly over `absorptionTime` (3 h when nil or 0).
public struct AdaptiveCarbEntry: Sendable, Equatable, Codable {
    public var date: Date
    public var grams: Double
    public var absorptionTime: TimeInterval?
    public init(date: Date, grams: Double, absorptionTime: TimeInterval? = nil) {
        self.date = date; self.grams = grams; self.absorptionTime = absorptionTime
    }
}

/// An active override: its correction range and insulin-needs factor (Loop's meaning: basal × f, ISF ÷ f, CR ÷ f).
public struct AdaptiveOverride: Sendable, Equatable, Codable {
    public var targetRange: ClosedRange<Double>?
    public var insulinNeedsFactor: Double?
    public init(targetRange: ClosedRange<Double>? = nil, insulinNeedsFactor: Double? = nil) {
        self.targetRange = targetRange; self.insulinNeedsFactor = insulinNeedsFactor
    }
}

/// Pump and safety limits. These are the only device settings the algorithm reads.
public struct AdaptiveLimits: Sendable, Equatable, Codable {
    /// U; nil = no limit
    public var maximumBolus: Double?
    /// U; automatic boluses are floored to it
    public var bolusIncrement: Double?
    /// mg/dL; used as the glucose safety limit when `AdaptiveParameters.glucoseSafetyLimitFromSettings`
    public var suspendThreshold: Double?
    /// U/h; nil = no limit. Not part of the Python reference; the temp basal never exceeds it.
    public var maximumBasalRate: Double?
    public init(maximumBolus: Double? = nil, bolusIncrement: Double? = nil, suspendThreshold: Double? = nil,
                maximumBasalRate: Double? = nil) {
        self.maximumBolus = maximumBolus; self.bolusIncrement = bolusIncrement
        self.suspendThreshold = suspendThreshold; self.maximumBasalRate = maximumBasalRate
    }
}

/// What is learned once, from the weeks before the algorithm takes over (see `AdaptiveProfile.estimate`).
public struct AdaptiveProfile: Sendable, Equatable, Codable {
    /// U/day: the starting scale TDD0 (already discounted, 0.9 × measured mean daily insulin)
    public var totalDailyDose: Double
    /// U/h: the starting background rate b0 (0.9 × median automatic delivery per clean hour)
    public var basalRate: Double
    /// mg/dL: the adaptive set point SP (mean CGM, clipped to 120...140)
    public var setPoint: Double
    public init(totalDailyDose: Double, basalRate: Double, setPoint: Double) {
        self.totalDailyDose = totalDailyDose; self.basalRate = basalRate; self.setPoint = setPoint
    }

    /// The candidate's profile rule from history summaries.
    /// - Parameters:
    ///   - dailyTotals: total insulin (basal + all boluses) for each complete recent day (14 days in the evaluation)
    ///   - hourlyAutomaticDelivery: basal + automatic boluses for each complete recent clock hour (same days)
    ///   - meanGlucose: mean CGM over the same days
    public static func estimate(dailyTotals: [Double], hourlyAutomaticDelivery: [Double], meanGlucose: Double,
                                discount: Double = 0.9) -> AdaptiveProfile? {
        guard !dailyTotals.isEmpty, !hourlyAutomaticDelivery.isEmpty, meanGlucose.isFinite else { return nil }
        let tdd = dailyTotals.reduce(0, +) / Double(dailyTotals.count)
        return AdaptiveProfile(totalDailyDose: discount * tdd,
                               basalRate: discount * median(hourlyAutomaticDelivery),
                               setPoint: min(max(meanGlucose, 120), 140))
    }

    static func median(_ v: [Double]) -> Double {      // linear interpolation, as numpy / pandas quantile(0.5)
        let s = v.sorted(), p = Double(s.count - 1) / 2
        let lo = Int(p.rounded(.down)), hi = Int(p.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (p - Double(lo))
    }
}

/// One decision request.
public struct AdaptiveInput: Sendable {
    public var now: Date
    /// ascending; the last ~3 h is enough (momentum 15 min, retrospective correction 30 min)
    public var glucose: [AdaptiveGlucoseSample]
    /// every dose whose action is not over (the last 6 h 10 min of starts; the evaluation passes 7 h)
    public var doses: [AdaptiveDose]
    /// entered carbs still absorbing (any entry within its absorption time)
    public var carbs: [AdaptiveCarbEntry]
    public var limits: AdaptiveLimits
    /// the person's own correction range; nil = the algorithm's default target
    public var userTarget: ClosedRange<Double>?
    /// the override active now, if any
    public var override: AdaptiveOverride?
    public init(now: Date, glucose: [AdaptiveGlucoseSample], doses: [AdaptiveDose], carbs: [AdaptiveCarbEntry] = [],
                limits: AdaptiveLimits = .init(), userTarget: ClosedRange<Double>? = nil, override: AdaptiveOverride? = nil) {
        self.now = now; self.glucose = glucose; self.doses = doses; self.carbs = carbs; self.limits = limits
        self.userTarget = userTarget; self.override = override
    }
}

/// The answer for the next 5 minutes.
public struct AdaptiveRecommendation: Sendable, Equatable {
    /// U, floored to the bolus increment
    public var automaticBolus: Double
    /// U/h; never above the background rate b
    public var tempBasalRate: Double
    /// U: the bolus calculator's answer (full need, carbs included, no application factor). Not floored.
    public var manualBolus: Double
    public var diagnostics: Diagnostics

    public struct Diagnostics: Sendable, Equatable {
        /// m
        public var scale: Double
        public var target: Double
        public var isf: Double
        /// b, U/h
        public var basalRate: Double
        /// IOB above steady background delivery, U
        public var netInsulin: Double
        public var carbUnits: Double
        public var retrospectiveCorrection: Double
        public var habitOffset: Double
        public var habitStrength: Double?
        /// G_h: the short forecast (momentum + RC), mg/dL
        public var forecast: Double
        /// U still owed (with the habit offset)
        public var need: Double
        public var glucoseSafetyHold: Bool
        public var forecastMinimum: Double?
    }
}
