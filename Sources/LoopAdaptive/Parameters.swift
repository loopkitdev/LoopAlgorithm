import Foundation

/// Fixed constants of the algorithm. The defaults are the evaluated Loop Adaptive candidate; none of them is a user
/// setting. Names follow the Python reference (`analysis/reduction/adaptive.py`, family `tdd_pd`) in comments.
public struct AdaptiveParameters: Sendable, Equatable, Codable {
    // dosing
    public var target: Double = 110            // target
    public var lowStop: Double = 80            // t_low: no insulin when G or G_h is below it
    public var bolusThreshold: Double = 120    // t_bolus: automatic boluses only at or above it
    public var momentumMinutes: Double = 30    // h
    public var slopeCap: Double = 3            // slope_cap, mg/dL/min
    public var riseCap: Double = 80            // rise_cap, mg/dL above current glucose
    public var applicationFactor: Double = 0.4 // af
    public var fallGate: Double = -1           // fall_gate, mg/dL/min
    public var tempFloor: Double = 80          // temp_floor_bg: the temp taper reaches 0 here
    public var targetMinimum: Double = 87      // target_min
    // scales from TDD
    public var isfK: Double = 688              // isf_k
    public var isfExponent: Double = 0.74      // isf_e
    public var carbRatioK: Double = 500        // cr_k (0 = ignore entered carbs)
    public var insulinPeak: Double = 75        // peak, minutes
    // retrospective correction
    public var retrospectiveGain: Double = 1   // rc_k
    public var retrospectiveCap: Double = 150  // rc_cap
    // adaptive scale m
    public var adaptRate: Double = 0.0139      // ad_k, per mg/dL·day
    public var adaptLowThreshold: Double = 80  // ad_lo
    public var adaptLowMultiplier: Double = 3  // ad_klo
    public var adaptMinimum: Double = 0.5      // ad_min
    public var adaptMaximum: Double = 2        // ad_max
    public var adaptBrakeHours: Double = 12    // ad_brake_h
    public var adaptEnabled: Bool = true       // ad_sp > 0
    // optional glucose safety limit
    public var glucoseSafetyLimit: Double = 0  // gsl (0 = off)
    public var glucoseSafetyLimitFromSettings: Bool = true // gsl_settings
    public var glucoseSafetyHorizon: Double = 180          // gsl_h, minutes
    // optional gated daily habit
    public var habitGain: Double = 0           // hab_k (0 = off)
    public var habitSkillReference: Double = 0.3 // hab_ref
    public var habitDays: Int = 7              // hab_days
    public var habitMinimumDays: Int = 3       // hab_min_days
    public var habitSkillHalfLifeDays: Double = 7 // hab_hl
    public var habitLow: Double = -60          // hab_lo
    public var habitHigh: Double = 80          // hab_hi
    // input guardrails (Guardrails.swift); the reference's `guard`, off there by default and ON here
    public var guardrails: Bool = true         // guard
    public var staleGlucoseMinutes: Double = 15 // g_stale_min: no automatic bolus on an older newest reading
    public var activeInsulinMultiplier: Double = 2 // g_iob_mult: net IOB ≤ this × maximum bolus (Loop's maxActiveInsulin)
    public var carbEntryMaximum: Double = 250  // g_carb_max, g per entry
    public var jumpLimit: Double = 40          // g_jump, mg/dL between readings ≤ 10.5 min apart
    /// The sensor's reporting limits: a reading at or above `sensorHigh` means at least that (HIGH), one at or below
    /// `sensorLow` means below it (LOW). Set them to the sensor's own range (e.g. Libre 3 reports up to 500).
    public var sensorLow: Double = 40          // g_cgm_lo
    public var sensorHigh: Double = 400        // g_cgm_hi
    public var staleDoseHistoryMinutes: Double = 15 // no automatic bolus when `doseHistoryDate` is older (Swift only)
    /// Count the doses this algorithm issued (automatic boluses and its 5-min temp basals, kept in `AdaptiveState`) as
    /// delivered when the dose history lacks them, so insulin whose record never reaches the phone is not given again.
    /// Swift only; LoopEval's engine turns it off to stay identical to the reference, whose dose records are complete.
    public var rememberIssuedBoluses: Bool = true

    public init() {}
    public static let candidate = AdaptiveParameters()
}

/// What the algorithm carries between cycles. Persist it; a fresh state starts at m = 1 with no habit memory.
public struct AdaptiveState: Sendable, Equatable, Codable {
    public var logScale: Double = 0
    public var lastUpdate: Date?
    public var lastLow: Date?
    public var habit = HabitMemory()
    /// doses issued in the last 6 h 10 min (guardrails, `rememberIssuedBoluses`)
    public var issued: [IssuedDose] = []
    public struct IssuedDose: Sendable, Equatable, Codable {
        public var time: Double; public var end: Double; public var units: Double; public var bolus: Bool
    }
    public init() {}
    public var scale: Double { exp(logScale) }
}

/// Clock-of-day memory of the unexplained glucose change, and its measured predictive skill.
public struct HabitMemory: Sendable, Equatable, Codable {
    var sums: [Int: Double] = [:]
    var counts: [Int: Int] = [:]
    var lastFed: Date?
    var lastFedValue: Double = 0
    var lastFedCensored = false
    var predictions: [Prediction] = []
    var feeds: [Feed] = []
    var pp = 0.0, rr = 0.0, pr = 0.0
    var scored = 0
    struct Prediction: Sendable, Equatable, Codable { var start: Double; var value: Double; var base: Double }
    struct Feed: Sendable, Equatable, Codable { var time: Double; var value: Double }
    public init() {}
}
