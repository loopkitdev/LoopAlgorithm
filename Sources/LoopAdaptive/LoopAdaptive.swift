import Foundation

/// The Loop Adaptive Algorithm: settings-free dosing from glucose, insulin delivered and (optionally) entered carbs.
///
/// Every 5 minutes, `recommend` returns an automatic bolus, a temp basal (used only to hold insulin back) and the bolus
/// calculator's answer. Person-specific scales come from the `AdaptiveProfile` learned once (TDD0, b0, set point) and
/// the slowly adapting scale m carried in `AdaptiveState`:
///
///     ISF  = isfK / TDD0^isfExponent ÷ f        b = b0 · m · f        CR = carbRatioK / (TDD0 · m · f)
///     G_h  = G + clamp(slope15, ±slopeCap) · momentumMinutes + RC (+ habit offset)
///     need = (min(G_h, G + riseCap) − T) / ISF − (IOB − b · IOB_eq) + COB / CR
///     bolus = applicationFactor · need   when need > 0, G ≥ bolusThreshold and slope > fallGate
///     temp  = b · clamp((G_ev − tempFloor) / (T − tempFloor), 0, 1),  G_ev = min(G_h, G + riseCap) − (net − COB/CR) · ISF
///     Δ ln m = adaptRate · e(G) · Δt,   e = G − SP above adaptLowThreshold, 3× faster downward below it
///
/// Reference implementation: LoopEval `analysis/reduction/adaptive.py`, family `tdd_pd` (parity-tested).
public enum LoopAdaptive {

    public static func recommend(_ raw: AdaptiveInput, profile: AdaptiveProfile, state: inout AdaptiveState,
                                 parameters p: AdaptiveParameters = .candidate) -> AdaptiveRecommendation {
        var input = raw
        var allCarbs: [AdaptiveCarbEntry]? = nil
        if p.guardrails {
            let c = Guardrails.clean(raw, p: p); input = c.input; allCarbs = c.allCarbs
            if p.rememberIssuedBoluses { input.doses += Guardrails.unrecorded(&state.issued, in: input) }
        }
        let curve = ExponentialCurve(peak: p.insulinPeak)
        let t = input.now.timeIntervalSince1970

        // target and override
        var target = p.target
        if let ut = input.userTarget { target = (ut.lowerBound + ut.upperBound) / 2 }
        var factor: Double? = nil
        if let ov = input.override {
            if let r = ov.targetRange { target = (r.lowerBound + r.upperBound) / 2 }
            factor = (ov.insulinNeedsFactor ?? 0) > 0 ? ov.insulinNeedsFactor! : 1
        }
        target = max(target, p.targetMinimum)
        let dT = target - p.target

        // no usable reading: no automatic bolus, the background rate (the pump's own fallback), m frozen
        if input.glucose.isEmpty {
            let m = adapt(&state, t: t, glucose: .nan, setPointShift: dT, frozen: true, profile: profile, p: p)
            var b = profile.basalRate * m * (factor ?? 1)
            if let mb = input.limits.maximumBasalRate { b = min(b, mb) }
            var d = AdaptiveRecommendation.Diagnostics(
                scale: m, target: target, isf: .nan, basalRate: b, netInsulin: .nan, carbUnits: 0, retrospectiveCorrection: 0,
                habitOffset: 0, habitStrength: nil, forecast: .nan, need: 0, glucoseSafetyHold: false, forecastMinimum: nil)
            d.noGlucose = true
            return AdaptiveRecommendation(automaticBolus: 0, tempBasalRate: b, manualBolus: 0, diagnostics: d)
        }
        let pieces = DosePieces(input.doses)
        let f = Features(input, curve: curve, pieces: pieces)
        let stale = p.guardrails && (t - f.latestTime) / 60 > p.staleGlucoseMinutes

        let m = adapt(&state, t: t, glucose: f.glucose, setPointShift: dT, frozen: factor != nil || stale, profile: profile, p: p)
        let fac = factor ?? 1
        let tdd = profile.totalDailyDose * m
        let isf = p.isfK / pow(profile.totalDailyDose, p.isfExponent) / fac
        let b = profile.basalRate * m * fac
        let slope = max(-p.slopeCap, min(p.slopeCap, f.slope15))
        var gh = f.glucose + slope * p.momentumMinutes
        let net = f.iob - b * curve.steadyStateHours

        var rc = 0.0
        if p.retrospectiveGain > 0 && f.span30 >= 20 {
            let d = f.dG30 + isf * (f.absorbed30 - b * f.span30 / 60)
            rc = max(-p.retrospectiveCap, min(p.retrospectiveCap, p.retrospectiveGain * d))
        }
        gh += rc
        let carbRatio: Double? = p.carbRatioK > 0 ? p.carbRatioK / (tdd * fac) : nil
        let carbUnits = carbRatio.map { f.cob / $0 } ?? 0

        var hab = 0.0, strength: Double? = nil
        if p.habitGain > 0 {
            Habit.feed(&state.habit, input: input, pieces: pieces, curve: curve, latest: f.latestTime, glucose: f.glucose,
                       isf: isf, basal: b, carbRatio: carbRatio, now: t, overrideActive: input.override != nil, p: p)
            let parts = Habit.parts(state.habit, at: t, p: p)
            let sk = Habit.skill(state.habit, p: p)
            if let parts {
                if p.habitSkillReference > 0 {
                    state.habit.predictions.append(.init(start: Double(Habit.bin(t) + 1) * 1800, value: parts.rel, base: parts.base))
                }
                hab = max(p.habitLow, min(p.habitHigh, p.habitGain * parts.rel)) * sk
            }
            strength = sk
        }

        var need0 = (min(gh, f.glucose + p.riseCap) - target) / isf - net + carbUnits
        let ghh = gh + hab
        let need = (min(ghh, f.glucose + p.riseCap) - target) / isf - net + carbUnits

        var bolus = 0.0, iobLimited = false
        if need > 0 && f.glucose >= p.bolusThreshold + dT && slope > p.fallGate {
            bolus = min(p.applicationFactor * need, (input.limits.maximumBolus ?? 0) > 0 ? input.limits.maximumBolus! : 1e9)
            if p.guardrails, let mb = input.limits.maximumBolus, mb > 0 {      // Loop's maxActiveInsulin
                let capped = max(0, min(bolus, p.activeInsulinMultiplier * mb - net))
                iobLimited = capped < bolus; bolus = capped
            }
        }
        let gev = min(ghh, f.glucose + p.riseCap) - (net - carbUnits) * isf
        var temp = b * min(1, max(0, (gev - p.tempFloor) / max(target - p.tempFloor, 5)))
        if f.glucose < p.lowStop || gh < p.lowStop { temp = 0 }
        if stale { bolus = 0; temp = f.glucose < p.lowStop ? 0 : b }
        // carb entries dated ahead: left out of automatic dosing, counted by the bolus calculator (a pre-bolus)
        if let all = allCarbs, all.count > input.carbs.count, let cr = carbRatio {
            need0 += (Features.carbsOnBoard(all, now: t) - f.cob) / cr
        }

        var hold = false, fcMin: Double? = nil
        var rec = max(0, need0)
        if p.glucoseSafetyLimit > 0 {
            let limit = (p.glucoseSafetyLimitFromSettings ? input.limits.suspendThreshold : nil) ?? p.glucoseSafetyLimit
            var ks: [Double] = []
            var k = 5.0
            while k <= p.glucoseSafetyHorizon + 1 - 1e-9 { ks.append(k); k += 5 }   // numpy arange(5, h + 1, 5)
            let (ins, cg) = future(input, pieces: pieces, curve: curve, now: t, ks: ks)
            var fc = [Double](repeating: 0, count: ks.count)
            for i in ks.indices {
                let km = min(ks[i], p.momentumMinutes)
                fc[i] = f.glucose + slope * km + rc * km / p.momentumMinutes - isf * (ins[i] - b * ks[i] / 60)
                if let cr = carbRatio { fc[i] += isf * cg[i] / cr }
            }
            let mn = fc.min() ?? f.glucose
            fcMin = mn
            if f.glucose < limit || mn < limit { bolus = 0; temp = 0; hold = true }
            if rec > 0 {
                var blocked = false, cap = Double.infinity, any = false
                for i in ks.indices {
                    let fr = 1 - curve.remaining(ks[i])
                    guard fr > 1e-6 else { continue }
                    any = true
                    if fc[i] < limit { blocked = true }
                    cap = min(cap, (fc[i] - limit) / (isf * fr))
                }
                if blocked { rec = 0 } else if any { rec = min(rec, cap) }
            }
        }
        if let mb = input.limits.maximumBasalRate { temp = min(temp, mb) }
        var historyStale = false
        if p.guardrails, let d = input.doseHistoryDate, t - d.timeIntervalSince1970 > p.staleDoseHistoryMinutes * 60 {
            bolus = 0; historyStale = true
        }

        var d = AdaptiveRecommendation.Diagnostics(
            scale: m, target: target, isf: isf, basalRate: b, netInsulin: net, carbUnits: carbUnits,
            retrospectiveCorrection: rc, habitOffset: hab, habitStrength: strength, forecast: gh,
            need: need, glucoseSafetyHold: hold, forecastMinimum: fcMin)
        d.glucoseStale = stale; d.doseHistoryStale = historyStale; d.activeInsulinLimited = iobLimited
        let given = floorTo(bolus, input.limits.bolusIncrement)
        if p.guardrails && p.rememberIssuedBoluses {
            if given > 0 { state.issued.append(.init(time: t, end: t, units: given, bolus: true)) }
            state.issued.append(.init(time: t, end: t + 300, units: temp / 12, bolus: false))
        }
        return AdaptiveRecommendation(automaticBolus: given, tempBasalRate: temp, manualBolus: rec, diagnostics: d)
    }

    /// The adaptive scale m: ln m integrates glucose against the set point; it does not rise for `adaptBrakeHours`
    /// after a reading below 70 and does not move while an override is on.
    static func adapt(_ s: inout AdaptiveState, t: Double, glucose g: Double, setPointShift: Double, frozen: Bool,
                      profile: AdaptiveProfile, p: AdaptiveParameters) -> Double {
        guard p.adaptEnabled else { return 1 }
        if let last = s.lastUpdate?.timeIntervalSince1970, !frozen, g.isFinite {
            let sp = profile.setPoint + setPointShift
            let dt = min(max(t - last, 0), 1800) / 86400
            if g < 70 { s.lastLow = Date(timeIntervalSince1970: t) }
            let err = g >= p.adaptLowThreshold ? g - sp : -p.adaptLowMultiplier * (p.adaptLowThreshold - g) + (p.adaptLowThreshold - sp)
            var d = dt * p.adaptRate * err
            if d > 0, let low = s.lastLow?.timeIntervalSince1970, t - low < p.adaptBrakeHours * 3600 { d = 0 }
            s.logScale = min(max(s.logScale + d, log(p.adaptMinimum)), log(p.adaptMaximum))
        }
        s.lastUpdate = Date(timeIntervalSince1970: t)
        return exp(s.logScale)
    }

    /// U of insulin and g of entered carbs absorbed in (now, now + k] for each k (minutes).
    static func future(_ input: AdaptiveInput, pieces: DosePieces, curve: ExponentialCurve, now t: Double,
                       ks: [Double]) -> ([Double], [Double]) {
        var ins = [Double](repeating: 0, count: ks.count), carbs = ins
        for j in pieces.times.indices where pieces.times[j] < t {
            let age = (t - pieces.times[j]) / 60, r0 = curve.remaining(age)
            for i in ks.indices { ins[i] += pieces.units[j] * (r0 - curve.remaining(age + ks[i])) }
        }
        for c in input.carbs {
            let el = (t - c.date.timeIntervalSince1970) / 60
            let dur = ((c.absorptionTime ?? 0) > 0 ? c.absorptionTime! : 10800) / 60
            let f0 = min(max(el / dur, 0), 1)
            for i in ks.indices { carbs[i] += c.grams * (min(max((el + ks[i]) / dur, 0), 1) - f0) }
        }
        return (ins, carbs)
    }

    static func floorTo(_ x: Double, _ inc: Double?) -> Double {
        guard let inc, inc > 0 else { return x }
        return (x / inc + 1e-9).rounded(.down) * inc
    }
}

/// Per-cycle measurements from the request.
struct Features {
    var glucose: Double, latestTime: Double
    var slope15: Double
    var dG30: Double, span30: Double, absorbed30: Double
    var iob: Double, cob: Double

    init(_ input: AdaptiveInput, curve: ExponentialCurve, pieces: DosePieces) {
        let t = input.now.timeIntervalSince1970
        let gt = input.glucose.map { $0.date.timeIntervalSince1970 }, gv = input.glucose.map(\.value)
        let last = gt.last ?? t
        glucose = gv.last ?? .nan; latestTime = last
        func window(_ minutes: Double) -> [Int] { gt.indices.filter { gt[$0] >= last - minutes * 60 - 30 } }
        // least-squares slope over the last 15 min, mg/dL per min
        let k15 = window(15)
        if k15.count >= 2 {
            let x = k15.map { (gt[$0] - last) / 60 }, y = k15.map { gv[$0] }
            let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
            var sxy = 0.0, sxx = 0.0
            for i in x.indices { sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) * (x[i] - mx) }
            slope15 = (x.max()! - x.min()!) > 0 && sxx > 0 ? (sxy / sxx * 1e9).rounded(.toNearestOrEven) / 1e9 : 0  // as the reference
        } else { slope15 = 0 }
        let k30 = window(30)
        if k30.count >= 2 {
            dG30 = gv[gv.count - 1] - gv[k30[0]]; span30 = (last - gt[k30[0]]) / 60
        } else { dG30 = 0; span30 = 0 }
        absorbed30 = span30 > 0 ? Features.absorbed(pieces, curve: curve, from: last - span30 * 60, to: last) : 0
        var iob = 0.0
        for j in pieces.times.indices {
            if pieces.isBolus[j] { iob += pieces.units[j] * curve.remaining((t - pieces.times[j]) / 60) }
            else if pieces.times[j] < t { iob += pieces.units[j] * curve.remaining((t - pieces.times[j]) / 60) }
        }
        self.iob = iob
        cob = Features.carbsOnBoard(input.carbs, now: t)
    }

    /// g of entered carbs not yet absorbed (linear over each entry's absorption time, 3 h by default; a future entry
    /// counts in full).
    static func carbsOnBoard(_ carbs: [AdaptiveCarbEntry], now t: Double) -> Double {
        var cob = 0.0
        for c in carbs {
            let el = (t - c.date.timeIntervalSince1970) / 60
            let dur = ((c.absorptionTime ?? 0) > 0 ? c.absorptionTime! : 10800) / 60
            if el >= 0 && el < dur { cob += c.grams * (1 - el / dur) } else if el < 0 { cob += c.grams }
        }
        return cob
    }

    /// U absorbed in (t0, t1] from every dose.
    static func absorbed(_ pieces: DosePieces, curve: ExponentialCurve, from t0: Double, to t1: Double) -> Double {
        var tot = 0.0
        for j in pieces.times.indices where pieces.times[j] < t1 {
            tot += pieces.units[j] * (curve.remaining((t0 - pieces.times[j]) / 60) - curve.remaining((t1 - pieces.times[j]) / 60))
        }
        return tot
    }
}
