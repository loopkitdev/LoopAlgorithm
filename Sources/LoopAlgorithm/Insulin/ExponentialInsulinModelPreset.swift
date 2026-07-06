//
//  ExponentialInsulinModelPreset.swift
//  LoopAlgorithm
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import Foundation

public enum ExponentialInsulinModelPreset: String, Codable {
    case rapidActingAdult
    case rapidActingChild
    case fiasp
    case lyumjev
    case afrezza
    /// Experiment: physiological LATE peak (90 min, from neg-ICE / clamp studies)
    /// with the SHORT effective duration (4h, from the fasting-tail metric). Its
    /// IOB curve nearly matches peak-55/DIA-6 (Loop's fiasp) — used to confirm
    /// control-equivalence of the physiologically-accurate model.
    case lateShort90dia4
}


// MARK: - Model generation
extension ExponentialInsulinModelPreset {
    public var actionDuration: TimeInterval {
        switch self {
        case .rapidActingAdult:
            return .minutes(360)
        case .rapidActingChild:
            return .minutes(360)
        case .fiasp:
            return .minutes(360)
        case .lyumjev:
            return .minutes(360)
        case .afrezza:
            return .minutes(300)
        case .lateShort90dia4:
            return .minutes(240)
        }
    }

    public var peakActivity: TimeInterval {
        switch self {
        case .rapidActingAdult:
            return .minutes(75)
        case .rapidActingChild:
            return .minutes(65)
        case .fiasp:
            return .minutes(55)
        case .lyumjev:
            return .minutes(55)
        case.afrezza:
            return .minutes(29)
        case .lateShort90dia4:
            return .minutes(90)
        }
    }

    public var delay: TimeInterval {
        switch self {
        case .rapidActingAdult:
            return .minutes(10)
        case .rapidActingChild:
            return .minutes(10)
        case .fiasp:
            return .minutes(10)
        case .lyumjev:
            return .minutes(10)
        case.afrezza:
            return .minutes(10)
        case .lateShort90dia4:
            return .minutes(10)
        }
    }

    public var model: InsulinModel {
        return ExponentialInsulinModel(actionDuration: actionDuration, peakActivityTime: peakActivity, delay: delay)
    }
}


extension ExponentialInsulinModelPreset: InsulinModel {
    public var effectDuration: TimeInterval {
        return model.effectDuration
    }

    public func percentEffectRemaining(at time: TimeInterval) -> Double {
        return model.percentEffectRemaining(at: time)
    }
}
