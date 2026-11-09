import Foundation

/// Optional gated daily habit (`AdaptiveParameters.habitGain` > 0).
///
/// Each new CGM interval feeds its unexplained change per 5 min — ΔG + ISF · (U absorbed − b · span) − ISF · (g of
/// entered carbs absorbed) / CR — into 30-minute clock bins (not while an override is on). The habit is the mean over
/// the previous `habitDays` days of the next 2 h of bins, minus 4 × the mean bin over those days. Its forecast offset
/// clamp(habitGain · habit, habitLow, habitHigh) is scaled by a skill gate, clamp(ρ / habitSkillReference, 0, 1), where ρ is an
/// EWMA correlation of each prediction with the 2 h of residual that followed (0 until 576 scored predictions).
enum Habit {
    static func bin(_ t: Double) -> Int { Int((t / 1800).rounded(.down)) }

    static func value(_ h: HabitMemory, _ b: Int) -> Double? {
        guard let n = h.counts[b], n >= 4, let s = h.sums[b] else { return nil }
        return s / Double(n) * 6                                       // mg/dL per 30 min
    }

    static func parts(_ h: HabitMemory, at t: Double, p: AdaptiveParameters) -> (rel: Double, base: Double)? {
        let b0 = bin(t), nd = p.habitDays
        var sums: [Double] = []
        for k in 1...max(1, nd) {
            var tot = 0.0, ok = true
            for j in 1...4 { if let v = value(h, b0 - 48 * k + j) { tot += v } else { ok = false; break } }
            if ok { sums.append(tot) }
        }
        guard sums.count >= p.habitMinimumDays else { return nil }
        var tot = 0.0, n = 0
        for b in (b0 - 48 * nd)..<b0 { if let v = value(h, b) { tot += v; n += 1 } }
        guard n > 0 else { return nil }
        let base = 4 * tot / Double(n)
        return (sums.reduce(0, +) / Double(sums.count) - base, base)
    }

    static func skill(_ h: HabitMemory, p: AdaptiveParameters) -> Double {
        guard p.habitSkillReference > 0 else { return 1 }
        guard h.scored >= 576, h.pp > 0, h.rr > 0 else { return 0 }
        return max(0, min(1, h.pr / (h.pp * h.rr).squareRoot() / p.habitSkillReference))
    }

    static func feed(_ h: inout HabitMemory, input: AdaptiveInput, pieces: DosePieces, curve: ExponentialCurve,
                     latest tg: Double, glucose g: Double, isf: Double, basal b: Double, carbRatio: Double?,
                     now t: Double, overrideActive: Bool, p: AdaptiveParameters) {
        let last = h.lastFed?.timeIntervalSince1970
        if let last, tg > last {
            let span = (tg - last) / 60
            if span <= 15 && !overrideActive {
                var r = (g - h.lastFedValue) + isf * (Features.absorbed(pieces, curve: curve, from: last, to: tg) - b * span / 60)
                if let cr = carbRatio { r -= isf * carbsAbsorbed(input.carbs, from: last, to: tg) / cr }
                let v = r * 5 / span
                let bb = bin(tg)
                h.sums[bb, default: 0] += v; h.counts[bb, default: 0] += 1
                h.feeds.append(.init(time: tg, value: v))
            }
        }
        if last == nil || tg > last! { h.lastFed = Date(timeIntervalSince1970: tg); h.lastFedValue = g }
        h.feeds.removeAll { $0.time <= t - 7200 }
        let decay = pow(0.5, 1 / max(1, p.habitSkillHalfLifeDays * 288))
        while let first = h.predictions.first, first.start <= t - 7200 + 150 {
            h.predictions.removeFirst()
            let w = h.feeds.filter { $0.time >= first.start }
            guard w.count >= 18 else { continue }
            let r = w.reduce(0) { $0 + $1.value } * 24 / Double(w.count) - first.base
            h.pp = decay * h.pp + first.value * first.value
            h.rr = decay * h.rr + r * r
            h.pr = decay * h.pr + first.value * r
            h.scored += 1
        }
        if h.sums.count > 48 * (p.habitDays + 2) {                     // keep only the bins `parts` can read
            let lo = bin(t) - 48 * (p.habitDays + 1)
            for k in h.sums.keys where k < lo { h.sums[k] = nil; h.counts[k] = nil }
        }
    }

    static func carbsAbsorbed(_ carbs: [AdaptiveCarbEntry], from t0: Double, to t1: Double) -> Double {
        var tot = 0.0
        for c in carbs {
            let d = c.date.timeIntervalSince1970
            let dur = (c.absorptionTime ?? 0) > 0 ? c.absorptionTime! : 10800
            tot += c.grams * (min(max((t1 - d) / dur, 0), 1) - min(max((t0 - d) / dur, 0), 1))
        }
        return tot
    }
}
