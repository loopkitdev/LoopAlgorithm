import Foundation

/// Loop's exponential insulin model (6 h action, 10 min delay): fraction of a dose still to act after t minutes.
struct ExponentialCurve: Sendable {
    let peak: Double, duration: Double, delay: Double
    let tau: Double, a: Double, s: Double
    init(peak: Double = 75, duration: Double = 360, delay: Double = 10) {
        self.peak = peak; self.duration = duration; self.delay = delay
        tau = peak * (1 - peak / duration) / (1 - 2 * peak / duration)
        a = 2 * tau / duration
        s = 1 / (1 - a + (1 + a) * exp(-duration / tau))
    }
    func remaining(_ minutes: Double) -> Double {
        let t = max(minutes - delay, 0)
        if t >= duration { return 0 }
        let r = 1 - s * (1 - a) * ((t * t / (tau * duration * (1 - a)) - t / tau - 1) * exp(-t / tau) + 1)
        return min(max(r, 0), 1)
    }
    /// IOB, in hours of rate, of a constant infusion that has run forever.
    var steadyStateHours: Double {
        var sum = 0.0
        var t = 0.0
        while t < duration + delay + 5 { sum += remaining(t); t += 1 }
        return sum / 60
    }
}

/// A dose as point masses: a bolus at its start, a basal segment in round((end - start) / 5 min) equal pieces at
/// their midpoints (banker's rounding, as the reference's Python `round`).
struct DosePieces {
    var times: [Double] = []
    var units: [Double] = []
    var automatic: [Bool] = []
    var isBolus: [Bool] = []
    init(_ doses: [AdaptiveDose]) {
        for d in doses {
            let a0 = d.start.timeIntervalSince1970, a1 = d.end.timeIntervalSince1970
            if d.kind == .bolus || a1 - a0 < 1 {
                times.append(a0); units.append(d.units); automatic.append(d.automatic); isBolus.append(true)
            } else {
                let n = max(1, Int(((a1 - a0) / 300).rounded(.toNearestOrEven)))
                for i in 0..<n {
                    times.append(a0 + (Double(i) + 0.5) * (a1 - a0) / Double(n)); units.append(d.units / Double(n))
                    automatic.append(d.automatic); isBolus.append(false)
                }
            }
        }
    }
}
