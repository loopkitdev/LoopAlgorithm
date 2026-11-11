import Foundation

/// Input guardrails (`AdaptiveParameters.guardrails`, on by default). The Python reference has the same rules under
/// `guard` (parity-tested); `doseHistoryDate` is checked here only.
///
/// - Sensor limits: a reading ≥ `sensorHigh` means at least that, one ≤ `sensorLow` means below it. It counts as the
///   limit (a bound: the dose for at least 400 is the dose for 400) and is censored: momentum and RC read uncensored
///   readings only, and are 0 when the newest reading is censored; the habit is not fed across a censored reading.
/// - Readings that are not finite, ≤ 0 or dated more than 60 s after `now` are dropped; readings are sorted, and at a
///   repeated time the last wins. Doses with non-finite or negative units, or starting more than 60 s after `now`, are
///   dropped. Carb entries that are not finite or ≤ 0 are dropped; each is capped at `carbEntryMaximum`.
/// - Upward jumps of more than `jumpLimit` mg/dL between readings ≤ 10.5 min apart:
///   - an isolated spike (above both neighbours by more than the limit) is dropped;
///   - a jump on the newest reading waits for the next reading;
///   - a confirmed jump is a level change, not a rate (momentum and RC read only the readings from it on).
///   Downward jumps are kept: they only ever withhold insulin.
/// - Carb entries dated more than 60 s ahead are left out of automatic dosing; the bolus calculator still counts them.
enum Guardrails {
    struct Cleaned {
        var input: AdaptiveInput      // with the carbs automatic dosing may read
        var allCarbs: [AdaptiveCarbEntry]
        var censored: [Bool]          // per reading of input.glucose: at a sensor limit
    }

    static func clean(_ input: AdaptiveInput, p: AdaptiveParameters) -> Cleaned {
        let t = input.now.timeIntervalSince1970, J = p.jumpLimit
        var byTime: [Double: AdaptiveGlucoseSample] = [:]
        for s in input.glucose where s.value.isFinite && s.value > 0 && s.date.timeIntervalSince1970 <= t + 60 {
            byTime[s.date.timeIntervalSince1970] = s
        }
        let lo = p.sensorLow, hi = p.sensorHigh
        var g: [(s: AdaptiveGlucoseSample, c: Bool)] = byTime.keys.sorted().map {
            let s = byTime[$0]!
            return (AdaptiveGlucoseSample(date: s.date, value: min(max(s.value, lo), hi)), s.value <= lo || s.value >= hi)
        }
        func close(_ a: AdaptiveGlucoseSample, _ b: AdaptiveGlucoseSample) -> Bool {
            let d = b.date.timeIntervalSince(a.date); return d > 0 && d <= 630
        }
        if g.count >= 3 {
            let src = g
            g = src.indices.compactMap { i in
                if i > 0 && i < src.count - 1 && close(src[i - 1].s, src[i].s) && close(src[i].s, src[i + 1].s)
                    && src[i].s.value - src[i - 1].s.value > J && src[i].s.value - src[i + 1].s.value > J { return nil }
                return src[i]
            }
        }
        if g.count >= 2 && close(g[g.count - 2].s, g[g.count - 1].s) && g[g.count - 1].s.value - g[g.count - 2].s.value > J {
            g.removeLast()
        }
        if g.count >= 2 {
            for i in stride(from: g.count - 1, to: 0, by: -1)
            where close(g[i - 1].s, g[i].s) && g[i].s.value - g[i - 1].s.value > J {
                g = Array(g[i...]); break
            }
        }
        var out = input
        out.glucose = g.map(\.s)
        out.doses = input.doses.filter { $0.units.isFinite && $0.units >= 0 && $0.start.timeIntervalSince1970 <= t + 60 }
        let carbs = input.carbs.compactMap { c -> AdaptiveCarbEntry? in
            guard c.grams.isFinite && c.grams > 0 else { return nil }
            var c = c; c.grams = min(c.grams, p.carbEntryMaximum); return c
        }
        out.carbs = carbs.filter { $0.date.timeIntervalSince1970 <= t + 60 }
        return Cleaned(input: out, allCarbs: carbs, censored: g.map(\.c))
    }

    /// Issued doses the dose history lacks, counted as delivered: an automatic bolus with no automatic bolus record
    /// starting within 10 min and within 0.05 U; a temp whose midpoint no basal record covers. Prunes the ledger to the
    /// insulin's action time.
    static func unrecorded(_ issued: inout [AdaptiveState.IssuedDose], in input: AdaptiveInput) -> [AdaptiveDose] {
        let t = input.now.timeIntervalSince1970
        issued.removeAll { $0.time < t - 370 * 60 }
        var boluses = input.doses.filter { $0.kind == .bolus && $0.automatic }.map { ($0.start.timeIntervalSince1970, $0.units) }
        let basal = input.doses.filter { $0.kind == .basal }.map { ($0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970) }
        var missing: [AdaptiveDose] = []
        for d in issued where d.time < t {
            if d.bolus {
                if let k = boluses.firstIndex(where: { abs($0.0 - d.time) <= 600 && abs($0.1 - d.units) <= 0.05 + 1e-9 }) {
                    boluses.remove(at: k); continue
                }
            } else {
                let mid = (d.time + d.end) / 2
                if basal.contains(where: { $0.0 <= mid && mid < $0.1 }) { continue }
            }
            missing.append(AdaptiveDose(start: Date(timeIntervalSince1970: d.time), end: Date(timeIntervalSince1970: d.end),
                                        units: d.units, kind: d.bolus ? .bolus : .basal, automatic: true))
        }
        return missing
    }
}
